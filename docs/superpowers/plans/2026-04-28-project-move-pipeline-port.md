# Project Move Pipeline Port (Node → Swift)

**Date**: 2026-04-28
**Status**: Stage 1 in progress
**Goal**: Implement the 4 MCP tools `project_move`, `project_archive`, `project_undo`, `project_move_batch` natively in Swift so they can be invoked through the Swift `EngramMCP` runtime that all clients now spawn (post 2026-04-28 cutover). Today these tools are missing from the Swift MCP tool list and `EngramServiceCommandHandler` rejects them with `unsupportedNativeCommand`.

## Why now

Cutover to Swift MCP shipped 2026-04-28 (`74b934a` … `2807259`). The 4 unported tools are the only behavioural gap vs. the retired Node MCP. Until they land:

- `EngramService` `projectMove/projectArchive/projectUndo/projectMoveBatch` handlers throw `unsupportedNativeCommand`
- Swift UI `RenameSheet` / `ArchiveSheet` / `UndoSheet` are gated behind `nativeProjectMigrationCommandsEnabled = false` (`ProjectMoveServiceError.swift`)
- MCP `tools/list` shows 22 tools, not 26

## Baseline (what we're porting)

| Node module | LOC | Role |
|-------------|-----|------|
| `src/core/project-move/orchestrator.ts` | 867 | 7-step pipeline + compensation |
| `src/core/project-move/sources.ts` | 295 | 7-source rename + cwd encoding rules |
| `src/core/project-move/jsonl-patch.ts` | 252 | CAS-safe JSONL `cwd` rewrite |
| `src/core/project-move/recover.ts` | 214 | Stuck-migration diagnosis |
| `src/core/project-move/retry-policy.ts` | 213 | Error → retryability classification |
| `src/core/project-move/gemini-projects-json.ts` | 191 | Gemini's `projects.json` mutation |
| `src/core/project-move/archive.ts` | 181 | Archive-as-move wrapper |
| `src/core/project-move/batch.ts` | 181 | YAML batch driver |
| `src/core/project-move/fs-ops.ts` | 154 | `safeMoveDir` |
| `src/core/project-move/lock.ts` | 132 | Inter-process advisory lock |
| `src/core/project-move/undo.ts` | 108 | Reverse migration replay |
| `src/core/project-move/review.ts` | 71 | Residual-references scan |
| `src/core/project-move/git-dirty.ts` | 63 | Working-tree state check |
| `src/core/project-move/paths.ts` | 22 | `expandHome` |
| `src/core/project-move/encode-cc.ts` | 19 | Claude Code dir encoding |
| `src/tools/project.ts` | 492 | MCP tool surface (handlers + schemas) |
| **Total** | **3,455** | |

Tests: 16 vitest files in `tests/core/project-move/` covering each module + integration + macOS path edge cases + cross-line-boundary CAS + stress.

## Stages

Each stage ends with: build green, tests pass, `git commit`, optional codex review.

### Stage 1 — Leaf utilities (no dependencies)

**Goal**: Foundational pure helpers that everything else uses; testable in isolation.

| Node module | LOC | Swift target |
|-------------|-----|--------------|
| `paths.ts` | 22 | `EngramCoreWrite/ProjectMove/Paths.swift` |
| `encode-cc.ts` | 19 | `EngramCoreWrite/ProjectMove/EncodeClaudeCodeDir.swift` |
| `git-dirty.ts` | 63 | `EngramCoreWrite/ProjectMove/GitDirty.swift` |
| `retry-policy.ts` | 213 | `Shared/EngramCore/RetryPolicy.swift` (or its existing analogue if already started) |
| `lock.ts` | 132 | `EngramCoreWrite/ProjectMove/MigrationLock.swift` |

Tests ported: `encode-cc.test.ts`, `git-dirty.test.ts`, `retry-policy.test.ts`. Lock test is integration-shaped (cross-process flock), keep that in Stage 2 or drop in favour of existing `ServiceWriterGate` flock pattern.

Estimated Swift LOC: ~600. Estimated time: 0.5–1 day.

### Stage 2 — Filesystem + JSONL primitives

| Node | Swift |
|------|-------|
| `fs-ops.ts` (154) | `FsOps.swift` |
| `jsonl-patch.ts` (252) | `JsonlPatch.swift` |
| `gemini-projects-json.ts` (191) | `GeminiProjectsJSON.swift` |

Tests ported: `fs-ops.test.ts`, `jsonl-patch.test.ts`, `cross-line-boundary.test.ts`, `gemini-projects-json.test.ts`, `macos-path-edge-cases.test.ts`.

Estimated Swift LOC: ~800. Estimated time: 1 day.

### Stage 3 — Sources + diagnostics

| Node | Swift |
|------|-------|
| `sources.ts` (295) | `Sources.swift` (7 source rules) |
| `review.ts` (71) | `Review.swift` |
| `undo.ts` (108) | `Undo.swift` |
| `recover.ts` (214) | `Recover.swift` |

Tests ported: `sources.test.ts`, `review.test.ts`, `undo-recover.test.ts`.

Estimated Swift LOC: ~900. Estimated time: 1 day.

### Stage 4 — Orchestrator + entrypoints + MCP wiring

| Node | Swift |
|------|-------|
| `orchestrator.ts` (867) | `Orchestrator.swift` |
| `archive.ts` (181) | `Archive.swift` |
| `batch.ts` (181) | `Batch.swift` |
| `tools/project.ts` (492) — handler half | `EngramMCP/Core/MCPProjectTools.swift` |
| EngramService stubs in `EngramServiceCommandHandler.swift` | replace 4 `unsupportedNativeCommand` calls with real pipeline invocations |
| `ProjectMoveServiceError.swift` `nativeProjectMigrationCommandsEnabled` | flip `false` → `true` |

Tests ported: `orchestrator.integration.test.ts`, `archive`-related portions of `lock-and-archive.test.ts`, `batch.test.ts`, `stress.test.ts` (or document subset that doesn't translate).

Estimated Swift LOC: ~2,200. Estimated time: 1.5–2 days.

## Open questions to resolve as we go

1. **YAML parsing** for `batch.ts`. Swift Foundation has no YAML; options: (a) shell out to `yq`, (b) add `Yams` SwiftPM dependency, (c) reject YAML at the MCP boundary and require JSON in the batch payload (breaking change to Node behaviour). Lean toward (b) — `Yams` is small and well-maintained. Decide at Stage 4.
2. **DB transaction scope**. Node uses `better-sqlite3`'s synchronous transactions; Swift uses GRDB's async-friendly `pool.write`. Verify orchestrator's compensation paths translate cleanly when the writer block is async.
3. **CAS semantics for `jsonl-patch.ts`**. The Node version reads file size + mtime + content hash, then writes back with O_EXCL + tmpfile + rename. Need to verify Swift FileManager / `Data` write APIs preserve the same atomicity. Stage 2 spike.
4. **`expandHome` in Swift**. NSString has `stringByExpandingTildeInPath`; need to confirm `~/` and `$HOME/` both work and the `$HOME` guard from `project_project_move.md` memory still applies.

## Out-of-scope for this port

- Performance benchmarking (Node baseline is "good enough"; ports aim for parity, not speedup).
- Removing the Node tree. Keep `src/core/project-move/` and `src/tools/project.ts` as parity baseline + executable spec until Stage 4 ships and is stable.

## Definition of done

- All 4 tools appear in Swift MCP `tools/list`
- All 4 tools succeed end-to-end on a fresh test fixture (move a synthetic project root with seeded sessions in 7 sources)
- `nativeProjectMigrationCommandsEnabled = true` flipped, UI sheets work
- 16 ported test files pass (XCTest equivalents)
- `EngramService` stubs removed; commit message references this plan
- `docs/mcp-swift.md` 26 tools claim updated to reflect parity restored
