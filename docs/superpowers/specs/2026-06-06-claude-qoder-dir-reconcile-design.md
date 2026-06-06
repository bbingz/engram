# Claude/Qoder Project Directory Reconcile Design

## Goal

Repair historical Claude Code and Qoder project directories that were left
under an obsolete encoded name by an older Engram project-move encoder, after
the session file contents already point at the current `cwd`.

## Problem

Claude Code and Qoder store project sessions under grouped directories whose
name is derived from `cwd`. Engram previously encoded only `/` and `.`, while
the real rule replaces every non-`[A-Za-z0-9]` UTF-16 code unit with `-`, with
the long-name truncate/hash branch. A past migration can therefore leave this
shape:

- directory basename: old/buggy encoded name
- session JSONL content: already patched to the new absolute `cwd`
- upstream client: looks in the corrected encoded directory and creates a new
  empty directory, so historical sessions become invisible to that client

The current project-move pipeline already avoids new instances by probing
actual grouped dirs containing the source `cwd`. This spec covers only the
standalone repair of already-orphaned grouped directories.

## Scope

In scope:

- Swift product implementation for startup maintenance.
- TypeScript reference implementation and tests.
- Claude Code and Qoder only, because both use `ClaudeCodeProjectDir.encode`.
- Dry-run/planning logic that reports the repair without side effects.
- Collision-safe apply logic that moves sessions with no-overwrite copy/delete
  semantics and never overwrites an existing target.

Out of scope:

- Gemini/iFlow reconcile. Their encoders are lossy and have different collision
  semantics already guarded by project-move preflight checks.
- Codex reconcile. Codex uses flat/date-tree roots, not cwd-encoded project
  directories.
- Merging two populated target directories automatically.
- Reading files larger than the existing structured-cwd cap.

## Safety Rules

1. Only inspect immediate child directories of the grouped source root.
2. Only trust structured JSONL/JSON `cwd` values at top level or
   `payload.cwd`; literal substring matches are not proof.
3. A directory is a repair candidate only when every discovered structured cwd
   in that directory encodes to the same target basename and the current
   basename differs from that target.
4. If a directory contains multiple structured cwd values that encode to
   different target basenames, skip it as ambiguous.
5. If the target directory already exists and is not the same real path, skip it
   as a collision.
6. Apply repairs with no-overwrite copy/delete semantics. The implementation
   must not rely on a precheck followed by an overwriting `rename`; if the
   target appears between plan and apply, count a collision and leave the source
   directory intact. If copy succeeds but source removal fails, report an issue
   and leave both directories for manual cleanup rather than deleting data.
7. Do not follow symlinks at any traversed level: immediate child symlinks are
   not candidates, and nested symlinks under a candidate directory are not
   scanned for cwd evidence.
8. Missing roots are no-ops.
9. Emit/report counts for scanned directories, planned/applied repairs,
   collisions, ambiguous directories, and scan issues.

## Startup Behavior

The Swift product runs reconcile during startup maintenance after ordinary DB
maintenance (`deduplicateFilePaths`, FTS optimize/vacuum, `reconcileInsights`)
and before parent-link cleanup, `cleanupStaleMigrations`, the `ready` event, and
orphan scanning. This timing keeps the operation out of the project-move
transaction path, records repair telemetry before readiness, and repairs source
directories before orphan scanning checks file accessibility.

## Verification

- Swift unit tests cover planning, dry-run, apply, target collision including
  apply-time race, ambiguous cwd skip, immediate and nested symlink skips,
  Qoder parity, startup invocation, startup ordering, and event emission.
- TypeScript unit tests cover the reference planner/applier with the same core
  filesystem cases.
- Existing project-move tests must remain green.
