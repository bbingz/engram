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

#### P1 residuals after Codex fix pass (re-verified 2026-07-05, Claude Code)

Codex's fix batches closed the *core* of P1: MCP `get_session` now surfaces
`truncatedAt` / `totalKnownComplete=false` and computes `totalPages` from the
capped window, `collectVisiblePageWindow` respects the cap via
`maxRawMessages`, the resume primer marks truncation, and markdown/JSON export
carry truncation metadata for the nine JSONL/cascade adapters that override
`streamMessagesWithMetadata`. Verified by re-reading the working tree plus green
focused suites (`AdapterWindowedReadTests`, `EngramMCPExecutableTests`,
`EngramWebUIServerTests`, `EngramServiceIPCTests`, `StartupBackfillTests`,
`DatabaseManagerTests`). The two residuals below were resolved on 2026-07-05 by
Codex:

- **Web UI oversized-transcript banner/clamp is dead code for indexed JSONL
  sessions, and its tests only exercise the pure helpers.** The banner/clamp
  trigger `EngramWebUIServer.transcriptTruncationMarker` (`:569`) fires only when
  `sessionMessageCount > transcriptMaxMessages` (10_000, `:35`) **or**
  `readTruncatedAt != nil`. Neither is reachable on the normal indexed path:
  (1) stored `message_count` is itself capped at ≤10_000 —
  `JSONLAdapterSupport.readObjects` stops appending at `limits.maxMessages`
  (`CodexAdapter.swift:93`, `ParserLimits.swift:19`) and `parseSessionInfo`
  counts only that capped object set (`CodexAdapter.swift:421`), so
  `count > 10_000` is never true; (2) the Web UI page read passes a non-nil
  `limit` (`EngramWebUIServer.swift:518`), so the adapter takes
  `shouldApplyMessageCap = options.limit == nil` = false
  (`CodexAdapter.swift:498`) and returns `truncatedAt = nil` (`:534`). Net: the
  banner never renders and the clamp never engages; because the same windowed
  read is uncapped, the Web UI actually pages the *full* transcript via
  `hasMore`/`nextOffset` (`:340`), so this is not data loss — it is inert
  defensive code plus an MCP-vs-WebUI inconsistency (MCP reports "truncated at
  10k", the Web UI serves everything). The three added tests
  (`EngramWebUIServerTests.swift:187`–`:219`) inject synthetic post-cap values
  (`sessionMessageCount: 10_001`, `truncatedAt: 10_000`) into the static helpers
  and never drive `sessionPage`/`readMessages` against a seeded >10k session, so
  they stay green while the production trigger is unreachable — false coverage.
  **Resolution:** Option B is now the explicit product behavior: Web UI
  transcript pages use raw-window pagination over the full transcript, while
  MCP/export whole-transcript surfaces remain capped and marked. The dead
  banner/clamp helpers and their helper-only tests were removed, and
  `EngramWebUIServerTests.testSessionPagePaginatesPastTenThousandWithoutTruncationBanner`
  now drives a real `/session/...` page over a seeded >10k-message Codex
  transcript.
- **Residual silent export truncation on adapters that do not override
  `streamMessagesWithMetadata`.** `KimiAdapter` (`:105`) and `OpenCodeAdapter`
  (`:220`) override only `streamMessages`, so they inherit the default
  `SessionAdapter.streamMessagesWithMetadata` (`SessionAdapter.swift:256`–`:264`)
  which always returns `truncatedAt = nil` / `totalKnownComplete = true`. An
  oversized (>10k message) session from either source therefore exports (and
  MCP-pages) capped at 10_000 with no truncation marker — the exact silent
  truncation P1 set out to remove, still present for these sources.
  **Resolution:** `KimiAdapter` and `OpenCodeAdapter` now override
  `streamMessagesWithMetadata` and report `truncatedAt = 10_000` /
  `totalKnownComplete = false` for whole-transcript reads that exceed the cap.
  Regression coverage lives in
  `EngramServiceIPCTests.testExportSessionMarksKimiOversizedTranscriptTruncated`
  and
  `EngramServiceIPCTests.testExportSessionMarksOpenCodeOversizedTranscriptTruncated`.

  **Validation:** focused
  `xcodebuild test -project Engram.xcodeproj -scheme EngramServiceCore
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` with the three
  new/changed `-only-testing` filters passed on 2026-07-05. The required
  `xcodebuild -project macos/Engram.xcodeproj -scheme Engram -configuration
  Debug build` also passed.

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
