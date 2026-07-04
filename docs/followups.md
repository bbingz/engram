# Engram Follow-ups

Follow-ups are verification gaps, low-priority refactors, or items that need
real data, UI exercise, or product confirmation before becoming TODOs.

## Open

Open workspace-hygiene follow-ups as of 2026-07-04:

- **Commit the documentation archive cleanup.** Current working tree contains
  root review/audit document moves into `docs/reviews/`, old-path reference
  updates, `MEMO.md`, and this backlog backfill. Before committing, verify with
  `git status --short --branch`, `git diff --check`, and a targeted `rg` for the
  old root review filenames / `audit/...` paths.
- **Resolve the preserved audit-remediation branch.**
  `codex-provider-audit-remediation` still tracks
  `origin/codex-provider-audit-remediation`; as of 2026-07-04,
  `git rev-list --left-right --cherry-pick --count main...codex-provider-audit-remediation`
  returned `28 4`, so it has four commits not on `main`. Review/merge it or
  explicitly close and delete it later; do not include it in stale-branch
  cleanup.
- **Decide whether to reclaim Time Machine snapshot space immediately.** Claude
  removed `macos/build` and `.claude/worktrees`, but `df -h .` still showed only
  about `64Gi` available because local Time Machine snapshots still reference
  deleted blocks. Let macOS purge them automatically, or explicitly thin/delete
  local snapshots if immediate disk space is required.
- **Normalize local ignore rules.** `.git/info/exclude` still contains local
  duplicates (`node_modules`, `.husky/_/`, `dist/`) and repo-specific entries
  such as `audit/` and `.github/copilot-instructions.md`. Decide which belong in
  shared `.gitignore` and which should remain local-only.

## Closed in cleanup

All follow-up items from the 2026-05-24 backlog cleanup pass have matching
implementation or verification coverage. Evidence is recorded in
`docs/backlog-cleanup-report.md`.
