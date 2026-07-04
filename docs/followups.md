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

## Open — perf-integration review findings (2026-07-04)

From the 18-agent adversarial review of the Codex-integrated 8-PR perf batch
(base `f9a236dc..main`). The one blocking item (fts_map self-heal ownership) was
already fixed on `main` (see `CHANGELOG.md`, new test
`FTSIncrementalTests.testReusedRowidWithUnchangedContentIsNotMaskedByStaleMap`).
The items below were each re-verified against real code and are left for a
follow-up fix pass. Every behavior change here needs a matching Swift test.

### P1 — oversized-transcript (>10k msgs) silent truncation makes totals/tails stale

- **Where:** `JSONLAdapterSupport.windowedMessages` and CodexAdapter's own
  path (`macos/Shared/EngramCore/Adapters/Sources/CodexAdapter.swift:210`, and
  the `.messageLimitExceeded` return around `:98`–`:113`); consumers
  `macos/EngramMCP/Core/MCPTranscriptReader.swift` (`fullScanPage` `:347`,
  `collectVisiblePageWindow` `:384`) and
  `macos/EngramService/Core/EngramWebUIServer.swift` (413 mapping near `:544`).
- **What changed:** an unwindowed read (`options.limit == nil`) that exceeds
  `ParserLimits.maxMessages` (10,000) no longer throws
  `.messageLimitExceeded`; it logs a private `.notice` and returns only the
  first 10k parsed records as success. This is a *deliberate, tested* change
  (AdapterWindowedReadTests) to avoid falling back to an uncapped legacy parser.
- **Why it's a problem:** two downstream call sites still assume "a whole read
  either fully succeeds or throws." MCP `get_session` now computes `totalPages`
  from a truncated total, so a client that pages to the reported last page
  believes it read the whole session while the tail past record ~10,000 is
  silently missing; the resume primer's "last messages" can likewise go stale.
  Separately, `collectVisiblePageWindow` (cache-hit fast path) asks the adapter
  for `StreamMessagesOptions(offset: 0, limit: rawLimit)`, which bypasses the
  10k cap that `fullScanPage` used to compute the cached total — so deep paging
  and the cached total disagree about how much content exists.
- **Needs a decision:** silent truncation vs. surfacing it. Preferred direction:
  thread a `truncated`/`totalKnownComplete` signal out of the adapter window so
  MCP totals, the resume primer, and the Web UI can report incompleteness
  (e.g. keep the 413 or add an explicit "transcript truncated at N" marker)
  instead of quietly capping. Confirm the intended UX before implementing.

### P2 — Web UI session-page ETag omits DB-mutable display fields

- **Where:** `macos/EngramService/Core/EngramWebUIServer.swift`
  `sessionETag(id:locator:offset:limit:)` (`:365`); rendered fields read in
  `sessionPage`/`readSession` and emitted at `:238`, `:245`, `:334`, `:338`,
  `:343`.
- **Problem:** the weak ETag hashes only session id + transcript file mtime/size
  + offset/limit. The page also renders `displayTitle`
  (`custom_name`/`generated_title`), `project`, and `messageCount`, all pulled
  from the `sessions` DB row and mutable without touching the transcript file
  (rename via `EngramServiceCommandHandler`, async title generation). A browser
  that cached the page gets a stale `304 Not Modified` after a rename/retitle,
  so the new title/project never appears.
- **Fix direction:** fold the DB-mutable rendered fields (or a cheap hash of
  them) into the ETag input so a rename/retitle changes the ETag.

### P2 — CursorAdapter parse cache keyed on shared WAL db mtime/size

- **Where:** `macos/Shared/EngramCore/Adapters/Sources/CursorAdapter.swift:126`
  (parse cache keyed via `ParsedTranscriptCache.Signature.forFile(dbPath)`).
- **Problem:** `state.vscdb` is Cursor/VSCode's live SQLite store, commonly in
  WAL mode; committed writes land in `-wal` and the main file's mtime/size can
  stay unchanged until a checkpoint. In the long-lived Web UI server, a composer
  edited while Cursor is open can serve stale cached messages.
- **Fix direction:** include the `-wal` (and `-shm`) sidecar mtime/size in the
  cache signature, or don't cache while the sidecar is non-empty.

### P3 — lower-impact / latent

- **FTS `optimize` gate blind to full rebuilds.**
  `macos/EngramCoreWrite/Indexing/StartupBackfills.swift` `optimizeFts` (`:625`)
  gates the FTS5 `optimize` merge on `ftsContentSignature` (`:650`), computed
  from `sessions`/`insights` aggregates. A `FTSRebuildPolicy` full rebuild
  doesn't move those aggregates, so on a future `expectedVersion` bump the freshly
  rebuilt multi-segment index is never merged. *Latent* until the next tokenizer/
  schema version bump. Fix: also gate on a rebuild marker/version, not just the
  content signature.
- **Whitespace-only query returns empty vs old browse-all.**
  `macos/Engram/Core/Database.swift` `keywordSearchSQL` (`:418`), `ctes.isEmpty`
  branch (`:445`). When `CJKText.ftsMatchTerms` yields `[]` (e.g. a 3-space
  query), the new CTE returns no rows; the old correlated-EXISTS query returned
  the most recent non-hidden sessions. Fix: restore the empty-term browse-all
  fallback (or short-circuit whitespace-only queries upstream).
- **`reconcileSkipTierIndexArtifacts` undercounts embeddings deletes.**
  `macos/EngramCoreWrite/Indexing/StartupBackfills.swift` (`:713`) discards the
  `session_embeddings` delete count, so the returned/logged `reconcile_skip_fts`
  total understates cleanup. *Latent* until sqlite-vec / `session_embeddings`
  is implemented. Fix: add the embeddings-delete row count to the return value.

## Closed in cleanup

All follow-up items from the 2026-05-24 backlog cleanup pass have matching
implementation or verification coverage. Evidence is recorded in
`docs/backlog-cleanup-report.md`.
