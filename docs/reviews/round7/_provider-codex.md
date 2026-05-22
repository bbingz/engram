# Provider validation — codex (GPT-5.x, codex-cli advanced runtime, real file access)

Status: COMPLETED (bounded re-run, task-mpgxy7s0; first attempt hung at 24min and
was cancelled). Codex read the report docs + spot-checked the load-bearing claims
against source. Verdict below; two corrections independently CONFIRMED by the lead
reviewer afterward (see notes).

## 1. V1/V2/V3 verdict
- **V1: TRUE.** `SessionSnapshotWriter.swift:302` inserts `session_index_jobs`; `:332` only deletes `sessions_fts`; no production `INSERT INTO sessions_fts(session_id, content)`. Reader `EngramServiceReadProvider.swift:341` starts from `sessions_fts f` joined to `sessions`.
- **V2: TRUE.** `EngramServiceRunner.swift:207-208` only calls `performWriteCommand("indexRecent")` → `writer.indexRecentSessions()`. No `migrate()`/`runInitialScan()` in `run()`.
- **V3: TRUE for the narrow mechanism.** `SessionBatchUpsert.swift:27` catches per-snapshot errors → `.failure`; `SwiftIndexer.swift:38` still `indexed += batch.count`.

## 2. SEC-C1/C2 verdict
- **SEC-C1: TRUE.** `EngramServiceRunner.swift:61` starts the web task unconditionally; `EngramWebUIServer.swift:39` bare router, routes `:40/:43/:49`, no auth/Host/Origin middleware; transcript render HTML-escape only (`:261`, `:428`).
- **SEC-C2: TRUE.** MCP `force` at `MCPToolRegistry.swift:1040`; handler passes `src`/`dst` at `EngramServiceCommandHandler.swift:884`; orchestrator only canonicalizes + self/inside checks (`Orchestrator.swift:210`) then physical move (`:345`). No allow-list.

## 3. Wrong / overstated claims (BOTH CONFIRMED by lead afterward)
- **V3 overstated at service level.** Per-batch fake count is TRUE, but `EngramDatabaseIndexer.indexSessions():53` runs inline backfills (`backfillPolycliProviderParents/SuggestedParents`) after `indexAll()`, which throw on a missing `sessions` table → the *service-level* scan FAILS (invisibly, per OBS-C2) rather than fake-completing. CONFIRMED: lead verified `indexSessions` runs the backfill `write{}` block at :53-55 before returning. Outcome (empty DB on fresh install) still holds; "reports success" → "fails invisibly."
- **SEC-C2 contrast with `linkSessions` overstated — and reveals a NEW bug.** The report said `linkSessions` rejects `Library/Keychains` via `containsSensitivePathComponent`, but that function splits the relative path by `/` into single components and compares each against a set containing the COMPOUND string `"Library/Keychains"` (`EngramServiceCommandHandler.swift:1257-1258`); no single component can equal it → the Keychains guard is INEFFECTIVE (`.ssh/.aws/.gnupg/.kube/.docker/.1password` single-component entries DO work). CONFIRMED by lead against source.

## 4. Concrete omissions
- `EngramDatabaseIndexer.indexStatus():73-75` returns `total:0, todayParents:0` when the `sessions` table is absent instead of failing → missing schema looks like an empty healthy DB (status masking; compounds OBS-C2 / V3). CONFIRMED.
- `NonWatchableSourceRescanner.swift:34` can drain jobs after rescans but has no production wiring found — another dead composition-root surface (supports the §3 root cause; distinct from StartupBackfills).
- The `linkSessions` compound-component guard bug above (new security gap).

## 5. Codex top-5 by severity
1. SEC-C1 unauthenticated always-on loopback Web UI serving raw transcripts.
2. V2 service never migrates or runs the startup/backfill/job-recovery chain.
3. V1 FTS jobs enqueued but no production content writer → new sessions unsearchable.
4. SEC-C2 `project_move` arbitrary writable-dir move via MCP (unconfined src/dst, force bypasses git-dirty only).
5. V3 per-snapshot failures swallowed + SwiftIndexer counts attempted snapshots as indexed.

Codex session: 019e4fd2-71b1-7c81-bd2a-840c39a70611
