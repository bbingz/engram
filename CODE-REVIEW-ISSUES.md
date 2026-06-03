# Engram Code Review: Consolidated Findings

> 5-round review covering branch `perf/transcript-paging`, TypeScript core, and Swift product.
> Generated 2026-06-03.

## Executive Summary

| Severity | Count |
|----------|-------|
| Critical | 0     |
| High     | 4     |
| Medium   | 13    |
| Low      | 19    |
| Info     | 1     |
| **Total** | **37** |

Test gap findings: 8 (separate section).

---

## 1. Branch-Specific Findings (`perf/transcript-paging`)

### High

#### H1. `currentMatchIndex` not clamped on search refinement

- **File:** `macos/Engram/Views/SessionDetailView.swift:667-674`
- **Status:** VERIFIED
- **Description:** `navigateFind()` indexes into `matchIndices` using `currentMatchIndex` without bounds checking. When the user refines a search and `matchIndices` shrinks, a stale `currentMatchIndex` causes an index-out-of-bounds crash on Cmd+Shift+G.
- **Suggested fix:** Clamp `currentMatchIndex` in `updateMatchIndicesDebounced()` after recomputing indices, or add a `guard currentMatchIndex < matchIndices.count` at the top of `navigateFind()`.

#### H2. `defer { isLoadingMore = false }` races with successor tasks

- **File:** `macos/Engram/Views/SessionDetailView.swift:719-720, 820-821`
- **Status:** PARTIALLY verified (narrow window)
- **Description:** Both `loadMoreMessages()` and `copyAllTranscript()` use `defer { isLoadingMore = false }`. If a predecessor task is cancelled and a successor starts, the predecessor's deferred reset can clobber the successor's loading state, leaving the UI in an inconsistent state.
- **Suggested fix:** Use a generation counter (monotonic task ID). Only clear `isLoadingMore` if the generation still matches at defer time.

### Medium

#### M1. `Task.detached` blocks don't observe parent cancellation

- **File:** `macos/Engram/Views/SessionDetailView.swift` (`rebuildIndexed`, `parseWindow`, `updateMatchIndicesDebounced`)
- **Description:** Several `Task.detached` closures perform substantial work (rebuilding indexed messages, parsing windows, scanning match indices) without checking `Task.isCancelled`. After a session switch, these orphaned tasks continue consuming CPU until completion.
- **Suggested fix:** Add `try Task.checkCancellation()` at loop iteration points inside each detached closure.

#### M2. Fire-and-forget `Task` in `showTranscriptStatus`

- **File:** `macos/Engram/Views/SessionDetailView.swift`
- **Description:** A `Task` is spawned for a timer but not tracked. If the view is dismissed before the timer fires, it writes to `@State` after the view's lifecycle ends.
- **Suggested fix:** Store the task in a `@State` property and cancel it in `onDisappear`.

#### M3. `copyAllTranscript` copies filtered subset

- **File:** `macos/Engram/Views/SessionDetailView.swift:704`
- **Description:** The function copies `displayIndexed` (the filtered/visible subset) rather than the raw transcript. The name implies "all." This is by design for the paging architecture but is misleading.
- **Suggested fix:** Rename to `copyVisibleTranscript()` or add a doc comment clarifying the behavior.

### Low

#### L1. `loadMoreButtonLabel` always shows "500"

- **File:** `macos/Engram/Views/SessionDetailView.swift:861-865`
- **Description:** The label uses `transcriptPageSize` (a constant 500) rather than the actual remaining message count. When fewer than 500 messages remain, the label is inaccurate.
- **Suggested fix:** Compute `min(transcriptPageSize, totalCount - displayedCount)` for the label.

#### L2. `displayVersion` not reset on session switch

- **File:** `macos/Engram/Views/SessionDetailView.swift:72, 90`
- **Description:** `displayVersion` is an ever-incrementing counter (`&+= 1`). It is never reset when the session changes. While not a bug (the token still changes), it is a defensive-reset gap.
- **Suggested fix:** Reset `displayVersion = 0` in the session-change handler.

#### L3. `showFind` not reset on session switch

- **File:** `macos/Engram/Views/SessionDetailView.swift:49`
- **Description:** If the find bar is open when the user switches sessions, it stays open with stale search text targeting the new session.
- **Suggested fix:** Reset `showFind = false` and `searchText = ""` on session change.

---

## 2. Cross-Cutting Findings: TypeScript Core

### High

#### H3. `chunker.ts` infinite loop when `overlap >= maxChars`

- **File:** `src/core/chunker.ts:61-68`
- **Status:** VERIFIED
- **Description:** `slidingWindow()` computes `step = windowSize - overlap`. When `overlap >= maxChars`, `step <= 0` and the `for` loop never advances, spinning indefinitely and causing OOM.
- **Suggested fix:** Validate inputs: `if (overlap >= maxChars) throw new Error(...)` or clamp `step = Math.max(1, windowSize - overlap)`.

### Medium

#### M4. `indexer.ts` `backfillCosts` missing transaction

- **File:** `src/core/indexer.ts:434-483`
- **Status:** VERIFIED
- **Description:** `backfillCosts()` calls `writeExtractedData()` for each session without wrapping the batch in a transaction. A crash mid-batch permanently loses tool/file/cost data for unprocessed sessions (no re-enqueue path). The catch block writes zero costs, marking the session as processed and excluding it from future backfills.
- **Suggested fix:** Wrap the batch loop in `db.transaction(...)`. Do not write zero-costs on stream failures; allow the error to bubble or leave the row unwritten for retry.

#### M5. `embeddings.ts` `setTimeout` missing `.unref()`

- **File:** `src/core/embeddings.ts:155, 172`
- **Status:** VERIFIED
- **Description:** Timer handles created by `setTimeout` for retry backoff are not `.unref()`'d. They prevent clean process exit when the Node event loop would otherwise be idle. Concurrent failures also spawn redundant timeouts.
- **Suggested fix:** Chain `.unref()` on each timer. Add a guard to prevent redundant timeouts.

#### M6. `web.ts` bearer token vulnerable to timing attack

- **File:** `src/web.ts:472-491`
- **Status:** VERIFIED (mitigated by localhost-only default)
- **Description:** Token comparison uses `!==` instead of `crypto.timingSafeEqual()`. An attacker could theoretically measure response timing to brute-force the token character by character.
- **Suggested fix:** Use `crypto.timingSafeEqual(Buffer.from(provided), Buffer.from(expected))` with equal-length buffers.

#### M7. `daemon.ts` port conflict crashes on `EADDRINUSE`

- **File:** `src/daemon.ts`
- **Status:** VERIFIED
- **Description:** If the configured port is already in use, the `listen()` call throws `EADDRINUSE` with no catch, crashing the daemon with no user-visible diagnostic.
- **Suggested fix:** Catch `EADDRINUSE`, log a clear message with the port number, and exit gracefully.

#### M8. `daemon.ts` disk-full crashes on unprotected writes

- **File:** `src/daemon.ts`
- **Status:** VERIFIED
- **Description:** SQLite writes in the file watcher callback are not wrapped in error handlers. `SQLITE_FULL` or `SQLITE_IOERR` crashes the daemon.
- **Suggested fix:** Wrap watcher write paths in try/catch; emit an `error` event and degrade gracefully.

#### M9. `fts-repo.ts` CJK regex missing Hangul range

- **File:** `src/core/db/fts-repo.ts:6`
- **Status:** VERIFIED
- **Description:** `CJK_REGEX` covers CJK Unified Ideographs and some radicals but omits Hangul (`가-힯`). Korean search queries hit the trigram tokenizer instead of the LIKE fallback, producing empty or wrong results.
- **Suggested fix:** Extend the regex: `/[⺀-鿿豈-﫿︰-﹏가-힯]/`.

#### M10. `fts-repo.ts` FTS retry changes query semantics

- **File:** `src/core/db/fts-repo.ts:114-118`
- **Status:** VERIFIED
- **Description:** On FTS syntax error, the retry path wraps the entire query in double quotes, turning a keyword search into a phrase search. Results differ silently.
- **Suggested fix:** Escape individual terms or use `NEAR()` instead of quoting the whole query. Document the semantic shift if intentional.

#### M11. `fts-repo.ts` `isFtsSyntaxError` matches non-FTS errors

- **File:** `src/core/db/fts-repo.ts:124-132`
- **Status:** VERIFIED
- **Description:** The error classifier matches on message substring patterns that can also hit schema corruption, I/O, or locked-database errors. Those should propagate, not be silently retried as phrase searches.
- **Suggested fix:** Narrow the match to FTS5-specific error codes only (e.g., check `err.code === 'SQLITE_ERROR'` AND message contains `fts5`).

### Low

#### L4. `vector-store.ts` `deleteInsight` missing transaction

- **File:** `src/core/vector-store.ts:460-462`
- **Description:** `deleteInsight` runs two separate `DELETE` statements (text + vec). A crash between them leaves an orphaned vec row.
- **Suggested fix:** Wrap in the existing `this.db.transaction(...)`.

#### L5. `vector-store.ts` dynamic transaction in `upsertInsight`

- **File:** `src/core/vector-store.ts:414-433`
- **Description:** `upsertInsight` creates a new transaction wrapper on each call rather than using the pre-prepared `this.upsertTxn`. Inconsistent with the rest of the class.
- **Suggested fix:** Use `this.upsertTxn(...)` consistently.

#### L6. `indexer.ts` uncached prepared statements

- **File:** `src/core/indexer.ts`
- **Description:** Several hot-path queries (e.g., `generateTitleIfNeeded`) create new `db.prepare()` calls per invocation instead of caching them. Minor performance overhead on large re-indexes.
- **Suggested fix:** Cache prepared statements in the constructor (pattern already used in `vector-store.ts`).

#### L7. `embedding-indexer.ts` unbounded Set

- **File:** `src/core/embedding-indexer.ts`
- **Description:** `EmbeddingIndexer` tracks processed sessions using an in-memory `Set<string>` that only grows. Bounded by DB size in practice, but no explicit cap. In long-running instances this is a slow memory leak.
- **Suggested fix:** Provide a `remove(sessionId)` method or replace with an SQL query for unindexed IDs.

#### L8. `watcher.ts` `shouldSkip` call outside try/catch

- **File:** `src/core/watcher.ts:114, 141`
- **Description:** `shouldSkip()` is invoked before the try block in the `unlink` listener. If the callback throws, the watcher crashes instead of logging and continuing.
- **Suggested fix:** Move the `shouldSkip` call inside the existing try/catch.

#### L9. `session-repo.ts` `deleteSession` not atomic

- **File:** `src/core/db/session-repo.ts:372`
- **Description:** `deleteSession` runs multiple DELETE statements (session, FTS, related tables) without a transaction wrapper. A crash between statements leaves orphaned FTS rows and vector entries.
- **Suggested fix:** Wrap in `db.transaction(...)`. Add cascade cleanup for `session_chunks`, `vec_sessions`, `vec_chunks`.

#### L10. `fts-repo.ts` correlated subquery in CJK fallback

- **File:** `src/core/db/fts-repo.ts:143`
- **Description:** The LIKE-based CJK fallback uses a correlated subquery (`SELECT MIN(f2.rowid)`) for grouping. Evaluates the LIKE full-text scan for every matched row.
- **Suggested fix:** Replace with a window function (`ROW_NUMBER() OVER(PARTITION BY ...)`).

#### L11. Adapters inner `readdir` not caught

- **File:** `src/adapters/commandcode.ts:36-42`, `src/adapters/claude-code.ts`, `src/adapters/qoder.ts`
- **Description:** Inner `readdir` calls for project subdirectories are not individually caught. One unreadable directory skips all remaining directories in the outer loop.
- **Suggested fix:** Wrap the inner `readdir` in its own try/catch.

#### L12. Adapters non-atomic cache writes

- **File:** `src/adapters/antigravity.ts`, `src/adapters/windsurf.ts`
- **Description:** Cache files are written with `writeFile` (not write-to-temp + rename). A crash mid-write corrupts the cache. Since cache validity relies on `mtime`, the corrupted file is parsed forever.
- **Suggested fix:** Write to a temp file, then `rename()` atomically.

#### L13. `web.ts` `/api/titles/regenerate-all` no duplicate guard

- **File:** `src/web.ts`
- **Description:** No idempotency check. Repeated calls spin up duplicate LLM polling loops, consuming AI quota unnecessarily. Rejections inside the spawned IIFE can crash the process.
- **Suggested fix:** Add an in-flight flag or mutex; return 409 if already running.

### Info

#### I1. `web.ts` unauthenticated GET endpoints

- **File:** `src/web.ts:472`
- **Description:** GET endpoints are intentionally unauthenticated (localhost-only by design). This is documented and acceptable for the current deployment model.

---

## 3. Cross-Cutting Findings: Swift Product

### High

#### H4. TS cascade trigger clears subagent tier unconditionally

- **File:** `src/core/db/migration.ts:152-159` vs `macos/EngramCoreWrite/Database/EngramMigrations.swift:61-78`
- **Status:** VERIFIED
- **Description:** The TypeScript trigger (`trg_sessions_parent_cascade`) sets `tier = NULL` on all orphaned children. The Swift trigger correctly preserves `tier = 'skip'` for `agent_role = 'subagent'`. This divergence means TS-migrated databases lose the subagent tier invariant. The TS trigger also does not clear `suggested_parent_id` children's tier, which the Swift trigger does.
- **Suggested fix:** Update the TS trigger to match Swift's conditional logic:
  ```sql
  UPDATE sessions SET parent_session_id = NULL, link_source = NULL,
    tier = CASE WHEN agent_role = 'subagent' THEN 'skip' ELSE NULL END
    WHERE parent_session_id = OLD.id;
  UPDATE sessions SET suggested_parent_id = NULL,
    tier = CASE WHEN agent_role = 'subagent' THEN 'skip' ELSE NULL END
    WHERE suggested_parent_id = OLD.id;
  ```

### Medium

#### M12. `EngramServiceRunner` `checkpointTask` not fully awaited

- **File:** `macos/EngramService/Core/EngramServiceRunner.swift:170-191`
- **Status:** VERIFIED
- **Description:** The periodic `checkpointTask` is cancelled at shutdown, but the final TRUNCATE checkpoint runs immediately after. If the periodic checkpoint was mid-flight when cancelled, WAL frames may not be flushed before the TRUNCATE, leaving stale WAL content for the next startup.
- **Suggested fix:** `await checkpointTask.value` after cancellation (with a timeout) before running the final TRUNCATE.

#### M13. Swift `clearParentSession` doesn't reset tier

- **File:** `macos/EngramCoreWrite/`
- **Status:** VERIFIED
- **Description:** When `clearParentSession()` unlinks a child, it does not reset the child's tier to `NULL` for re-evaluation. The TS equivalent does. This means manually unlinked children retain their old tier instead of being re-evaluated.
- **Suggested fix:** Add `tier = NULL` (or the subagent-aware CASE) to the `clearParentSession` UPDATE.

#### M14. Swift `replaceTable()` DROP + RENAME not atomic

- **File:** `macos/EngramCoreWrite/Database/EngramMigrations.swift:432-448` (and 13 other call sites)
- **Status:** VERIFIED
- **Description:** `replaceTable()` executes `DROP TABLE old` then `ALTER TABLE replacement RENAME TO old` as separate statements. A crash between the DROP and RENAME loses the table entirely. All migration V2 upgrades use this pattern.
- **Suggested fix:** Wrap both statements in a single `db.transaction { }`.

### Low

#### L14. Swift `mutateEngramSettings` not atomic

- **File:** `macos/Engram/Views/Settings/`
- **Description:** Settings mutations read-modify-write without a lock. Safe today (single-threaded UI) but fragile if a service callback ever modifies settings concurrently.
- **Suggested fix:** Low priority; document the single-threaded assumption.

#### L15. `MCPTranscriptTools` force unwrap

- **File:** `macos/EngramMCP/Core/MCPTranscriptTools.swift:23`
- **Description:** `activeRoleFilter!.contains($0.role)` force-unwraps an optional. Safe because the preceding `filter` condition guards it, but the intent is unclear.
- **Suggested fix:** Use `activeRoleFilter?.contains($0.role) ?? true` for clarity.

#### L16. MCP duplicates CJK helper

- **File:** `macos/EngramMCP/`
- **Description:** The MCP target has its own copy of the CJK detection regex/logic instead of importing from a shared module. Risks drift (e.g., the Hangul gap in M9 may or may not exist here).
- **Suggested fix:** Extract to `EngramCoreRead` or `EngramCore` shared module.

#### L17. `link_checked_at` not cleared on re-index

- **File:** `macos/EngramCoreWrite/`
- **Description:** When a session is re-indexed, `link_checked_at` retains its old value. Stale suggested-parent links are not re-evaluated because the heuristic backfill skips sessions where `link_checked_at IS NOT NULL`.
- **Suggested fix:** Clear `link_checked_at` in the session upsert path.

#### L18. No self-link guard in snapshot upsert

- **File:** `macos/EngramCoreWrite/`
- **Description:** The snapshot/restore path does not guard against `parent_session_id = id`. The runtime path has this check; the snapshot path does not.
- **Suggested fix:** Add a CHECK constraint or application-level guard in the snapshot upsert.

---

## 4. Test Coverage Gaps

| ID | Gap | Priority |
|----|-----|----------|
| T1 | `chunker.ts` sliding window: no test for `overlap >= maxChars` infinite loop case | High |
| T2 | `vacuumIfNeeded` true branch: never tested with actual VACUUM execution | Medium |
| T3 | No concurrent write safety tests (neither TS nor Swift) | Medium |
| T4 | `web.ts` bearer auth only tested on 1 endpoint; most write endpoints untested | Medium |
| T5 | `backfillCosts` transaction atomicity: no crash-recovery test | Medium |
| T6 | `parseWindowed` all-tool window: 0 displayable messages untested | Low |
| T7 | `parseWindowed` past EOF: untested boundary | Low |
| T8 | `parseWindowed` empty file: untested boundary | Low |

---

## 5. Positive Findings

- **Paging architecture is sound.** The threshold-gated lazy streaming approach correctly avoids O(N^2) re-parsing. The `displayVersion` token-based invalidation is clean.
- **Swift cascade trigger is correct.** The `CASE WHEN agent_role = 'subagent'` guard properly preserves the subagent tier invariant. The TS side just needs to catch up.
- **CJK LIKE fallback exists.** The `containsCJK` check and LIKE fallback path show awareness of the trigram tokenizer's CJK limitations. The Hangul gap is a minor oversight.
- **Bearer auth is scoped correctly.** Only write (`/api/*`) endpoints require auth; read endpoints are intentionally open on localhost. The architecture is reasonable.
- **Prepared statement caching in `vector-store.ts`.** The constructor pre-prepares all hot-path statements, following best practices. The rest of the codebase should follow this pattern.
- **WAL checkpoint lifecycle.** The dual-checkpoint approach (periodic PASSIVE + startup TRUNCATE + shutdown TRUNCATE) is well-designed for the service lifecycle.
- **Test infrastructure is real.** Tests use actual fixtures and file I/O, not mocks. This catches integration issues that unit tests miss.

---

## Appendix: Finding Cross-Reference

| Finding | Severity | Area | Verified |
|---------|----------|------|----------|
| H1 | High | Swift/PR | Yes |
| H2 | High | Swift/PR | Partial |
| H3 | High | TS Core | Yes |
| H4 | High | Cross-runtime | Yes |
| M1 | Medium | Swift/PR | -- |
| M2 | Medium | Swift/PR | -- |
| M3 | Medium | Swift/PR | -- |
| M4 | Medium | TS Core | Yes |
| M5 | Medium | TS Core | Yes |
| M6 | Medium | TS Core | Yes |
| M7 | Medium | TS Core | Yes |
| M8 | Medium | TS Core | Yes |
| M9 | Medium | TS Core | Yes |
| M10 | Medium | TS Core | Yes |
| M11 | Medium | TS Core | Yes |
| M12 | Medium | Swift | Yes |
| M13 | Medium | Swift | Yes |
| M14 | Medium | Swift | Yes |
| L1-L3 | Low | Swift/PR | -- |
| L4-L13 | Low | TS Core | -- |
| L14-L18 | Low | Swift | -- |
| I1 | Info | TS Core | Yes |
| T1-T8 | Test gaps | -- | -- |
