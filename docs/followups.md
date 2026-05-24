# Engram Follow-ups

Follow-ups are verification gaps, low-priority refactors, or items that need
real data, UI exercise, or product confirmation before becoming TODOs.

## Open

### Project migration UI smoke

- **Module:** `macos/Engram/Views/Projects`, `macos/EngramService/Core`
- **Type:** follow-up
- **Source:** `docs/backlog-audit-2026-05-24.md`
- **Acceptance:** A disposable app-hosted or manual smoke verifies the committed
  Rename / Archive / Undo flow through the UI, including disabled states and the
  final service state.
- **Related files:** `ProjectsView.swift`, `RenameSheet.swift`,
  `ArchiveSheet.swift`, `UndoSheet.swift`
- **Status:** open

### Project recover `fs_done` E2E

- **Module:** project move recovery
- **Type:** follow-up
- **Source:** `docs/backlog-audit-2026-05-24.md`
- **Acceptance:** A disposable end-to-end scenario leaves a migration in
  `fs_done`, runs `project_recover`, and verifies the recommendation against the
  actual filesystem and database state.
- **Related files:** `RecoverMigrationsTests.swift`,
  `tests/core/project-move/undo-recover.test.ts`
- **Status:** open

### Batch move large-data smoke

- **Module:** project move batch
- **Type:** follow-up
- **Source:** `docs/backlog-audit-2026-05-24.md`
- **Acceptance:** Run batch moves against a large disposable session corpus and
  record runtime, failure handling, and post-run migration-log consistency.
- **Related files:** `BatchTests.swift`, `src/core/project-move`
- **Status:** open

### Archive heuristic boundary corpus

- **Module:** project archive
- **Type:** follow-up
- **Source:** `docs/backlog-audit-2026-05-24.md`
- **Acceptance:** Expand archive heuristic coverage with a larger boundary corpus
  that exercises empty, historical-script, archived-done, git-file worktree, and
  ambiguous project shapes.
- **Related files:** `ArchiveTests.swift`,
  `tests/core/project-move/lock-and-archive.test.ts`
- **Status:** open

### UndoSheet keyboard and CAS precision

- **Module:** project move UI / JSONL patching
- **Type:** follow-up
- **Source:** `docs/backlog-audit-2026-05-24.md`
- **Acceptance:** Verify keyboard navigation in `UndoSheet`; decide whether file
  mtime precision is sufficient for CAS protection or add a stronger guard.
- **Related files:** `UndoSheet.swift`, `JsonlPatch.swift`, `jsonl-patch.ts`
- **Status:** open

### Swift CLI resume scope confirmation

- **Module:** CLI / resume
- **Type:** follow-up
- **Source:** `docs/backlog-audit-2026-05-24.md`
- **Acceptance:** Confirm whether `EngramCLI` intentionally remains MCP-stdio
  only, or promote a concrete Swift CLI resume task into `docs/TODO.md`.
- **Related files:** `macos/EngramCLI/main.swift`, `ResumeDialog.swift`
- **Status:** needs-confirmation

### Smart dirty-worktree policy

- **Module:** project move safety
- **Type:** follow-up
- **Source:** `docs/backlog-audit-2026-05-24.md`
- **Acceptance:** Decide whether whitespace-only or untracked-only dirt should
  stay force-gated, or become an explicit safe path with tests.
- **Related files:** `git-dirty.ts`, `GitDirty.swift`
- **Status:** needs-confirmation

### Oversized JSONL patching policy

- **Module:** project move JSONL patching
- **Type:** follow-up
- **Source:** `docs/backlog-audit-2026-05-24.md`
- **Acceptance:** Decide whether the 128 MiB cap remains a deliberate refusal or
  add streaming patch support with tests on large files.
- **Related files:** `jsonl-patch.ts`, `Sources.swift`
- **Status:** needs-confirmation

### Live updates transport

- **Module:** web / live activity
- **Type:** follow-up
- **Source:** `docs/backlog-audit-2026-05-24.md`
- **Acceptance:** Confirm that polling-only `/api/live` remains the product
  choice, or promote an SSE endpoint into `docs/TODO.md`.
- **Related files:** `src/web.ts`, `SourcePulseView.swift`
- **Status:** needs-confirmation

## Closed in cleanup

Five follow-up items were closed during the backlog cleanup pass. The remaining
verification and product-confirmation gaps are tracked above rather than hidden
as closed.
