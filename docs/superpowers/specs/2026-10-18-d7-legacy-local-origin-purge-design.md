# Design Doc: D7 legacy origin=local grok/pi purge is a dry-run-first operator action

- **Status**: Accepted (implemented in the same PR)
- **Owner**: Engram maintainers (Claude session, 2026-10-18)
- **Date**: 2026-10-18
- **Related**: `docs/superpowers/specs/2026-10-02-hq-local-collector-cutover-design.md`
  §2 ("The existing ~6,140 `origin=local` grok/pi rows (DECISION D7)",
  :397-418), decision table row D7 (:656) and the recorded decision (:687:
  option (c), a dry-run-first purge that also clears derived rows, before
  D4); `docs/TODO.md` "D7 purge of legacy `origin=local` grok/pi rows";
  CHANGELOG 2026-10-17 status check (6,191 rows: grok 5,959, pi 232; no
  dry-run tooling); `docs/invariants.md` "Legacy Host Scan Runs Only in the
  Local Role".

## Problem

Before the role gate (cutover P1, invariant "Legacy Host Scan Runs Only in
the Local Role"), the HQ index-role service still ran the legacy host scan
and stored grok and pi sessions with `origin=local`. The 2026-10-17 status
check counted 6,191 such rows in the central DB (grok 5,959, newest
2026-10-07 11:20 UTC; pi 232, newest 2026-09-11), unchanged since the gate,
so they no longer grow. They are inert for the Web reader (capture-bound),
but they duplicate the HQ capture rows for every reader that ignores capture
bindings: the App or MCP pointed at the central DB, and service IPC reads.
D4 (HQ MCP on the central DB) must not land on top of them. The decision
(cutover design :687) is option (c): an explicit purge through
`ServiceWriterGate`, dry-run first, that also clears derived rows, and only
if the dependent count is zero. Nothing existed to produce that dry run or
to perform the purge without hand-written SQL on a live host.

## Goals / Non-goals

- Goals:
  - an exact dry-run report that runs on a read-only backup copy without a
    running service, and the same report from the live service;
  - a purge that executes exactly the approved plan (session count plus a
    plan token over the sorted IDs), in one transaction under
    `ServiceWriterGate`, only in a service started with role `index`;
  - refusal when any user-state dependent count is non-zero;
  - removal of the rows' derived rows (FTS, rebuild shadow, fts_map, index
    jobs, costs, tools, beats, files, chunks, queues, ledger) in the same
    transaction, with verified counts;
  - an audit row in `metadata`;
  - never touching capture-bound rows, peer imports or other sources.
- Non-goals: option (b), the W4.1 same-host alias; other sources; `VACUUM`;
  any change to the capture ledger or identity bindings; cleanup of
  `file_index_state` or `ai_audit_log`; automatic or startup purges; any UI.
  The HQ deploy and the apply itself are owner-run mutations outside this
  PR.

## Current state

At `4b84e3d5`:

- The legacy scan writes `authoritativeNode = "local"`
  (`macos/EngramCoreWrite/Indexing/SwiftIndexer.swift:23`); `origin`
  defaults to `'local'` (`macos/EngramCoreWrite/Database/EngramMigrations.swift:33`)
  and the writer stores `snapshot.origin ?? snapshot.authoritativeNode`
  (`macos/EngramCoreWrite/Indexing/SessionSnapshotWriter.swift:754`).
- Capture commits use `authoritativeNode = origin = capture-v1.<machine>.<instance>`
  and IDs in the `remote:<peer>:<b64>` namespace
  (`macos/EngramCoreWrite/CaptureIngest/CaptureIngestIdentity.swift`), and each
  stored session gets a `capture_ingest_identity_bindings` row and
  `capture_ingest_generations` rows whose `stored_session_id REFERENCES
  sessions(id)` has no `ON DELETE` action
  (`macos/EngramCoreWrite/CaptureIngest/CaptureIngestCommitter.swift:186-215`).
  Peer imports carry `origin = <peer>`.
- The existing local-origin predicate is
  `COALESCE(NULLIF(TRIM(origin),''),'local')='local'`
  (`macos/EngramCoreWrite/Indexing/StartupComposition.swift:330`).
- Session-keyed tables: FK `ON DELETE CASCADE` for `session_local_state`,
  `session_relations`, `session_index_jobs`, `session_costs`,
  `session_tools`, `session_work_beats`, `session_files`, `semantic_chunks`,
  `offload_queue`, `rehydrate_queue`, `sync_ledger`; no FK for
  `sessions_fts` (FTS5, `session_id UNINDEXED`), `fts_map`,
  `sessions_fts_rebuild`, `insights` / `memory_insights.source_session_id`,
  `ai_audit_log.session_id`, `file_index_state` (keyed by source and
  locator), and the lazily created `favorites` / `tags`. Legacy `messages`
  and `session_embeddings` may exist. The only trigger,
  `trg_sessions_parent_cascade`, nulls parent and suggested-parent links on
  other rows when a session is deleted.
- `StartupBackfills` already removes session artifacts table by table in
  one transaction (derived rows first, `tableExists` guards), which this
  design copies.
- Operator commands use `writerGate.performWriteCommand` / `performReadCommand`,
  `ServiceCapabilityToken.protectedCommands`, and the EngramCLI archive
  parser/runner shape (`macos/Shared/Service/EngramCLIArchiveCommand.swift`).
  EngramCLI links no GRDB and only speaks IPC.

## Proposed design

No schema change.

**Candidate predicate** (`LegacyLocalSessionPurge.candidateSQL`):

```sql
SELECT s.id FROM sessions s
WHERE s.source IN ('grok','pi')
  AND COALESCE(NULLIF(TRIM(s.origin),''),'local')='local'
  AND COALESCE(NULLIF(TRIM(s.authoritative_node),''),'local')='local'
  AND s.id NOT LIKE 'remote:%'
  AND NOT EXISTS (SELECT 1 FROM capture_ingest_identity_bindings b WHERE b.stored_session_id=s.id)
  AND NOT EXISTS (SELECT 1 FROM capture_ingest_generations g WHERE g.stored_session_id=s.id)
```

- Origin and authority must both be local: a capture or peer row carries a
  non-local value in at least one of them.
- `remote:` is the capture and peer-import ID namespace; a local legacy ID
  never starts with it.
- The binding and generation clauses exclude any row the capture pipeline
  owns, even one that somehow kept a local origin. They are emitted only when
  the tables exist, so an older backup copy still reports. As a backstop,
  those FKs have no `ON DELETE` action, so SQLite would reject deleting a
  bound row and roll the transaction back.

**Report** (`LegacyLocalSessionPurge.report`, SELECT-only, no TEMP tables):

| Field | Meaning |
|---|---|
| `predicateVersion` | `1` |
| `sessionCount`, `planToken` | candidate count; token below |
| `sources` | per source: `sessions`, `newestIndexedAt`, `newestStartTime` |
| `blocking` | user-state dependents; every key always present |
| `derived` | rows the purge deletes with the sessions |
| `retained` | reported, never deleted |
| `captureBoundExcluded` | grok/pi rows with local origin and authority that are capture-bound |
| `otherLocalOriginSessions` | local-origin rows of other sources, by source |
| `purgeAllowed` | `sessionCount > 0` and every blocking value is 0 |

Blocking keys: `sessionLocalState`, `rowCustomName`, `rowHidden`,
`manualLinks` (`link_source='manual'`, which includes manual unlinks),
`externalConfirmedChildren` and `externalSuggestedChildren` (rows outside the
candidate set whose parent or suggested parent is a candidate),
`sessionRelations`, `favorites`, `tags`, `insights`, `memoryInsights`,
`offloaded` (`offload_state != 'local'`).

Derived keys: `messages`, `sessionsFts`, `sessionsFtsRebuild`, `ftsMap`,
`sessionEmbeddings`, `semanticChunks`, `sessionIndexJobs`, `sessionCosts`,
`sessionTools`, `sessionWorkBeats`, `sessionFiles`, `offloadQueue`,
`rehydrateQueue`, `syncLedger`. A missing table reports 0.

Retained keys: `fileIndexState` (grok/pi `file_index_state` rows whose
locator is a candidate's `file_path` or `source_locator`) and `aiAuditLog`.

**Plan token**: lowercase hex SHA-256 over the UTF-8 bytes
`engram-legacy-local-purge-v1\n` followed by each candidate ID in
`ORDER BY s.id` (SQLite BINARY) order, each followed by `\n`. An empty set
has a token too. This is exactly what
`printf 'engram-legacy-local-purge-v1\n'; sqlite3 ... "SELECT s.id ... ORDER BY s.id"`
prints, so the operator can recompute it independently.

**Purge transaction** (`LegacyLocalSessionPurge.purge`, inside the caller's
`writer.write`):

1. Refuse outside a transaction (`notInTransaction`).
2. Recompute the report. A different count or token throws `planChanged`
   with the current values; any non-zero blocking key throws
   `blockingDependents` with only those keys; an empty set throws
   `nothingToPurge`.
3. Delete each derived table's rows for the candidates while the sessions
   still exist, recording `changesCount` per key; require them to equal the
   planned counts and the remaining derived counts to be 0.
4. `DELETE FROM sessions WHERE id IN (candidates)`; require the change count
   to equal the expected count and the candidate set to be empty afterwards.
5. `INSERT INTO metadata(key, value)` (no `OR REPLACE`) with key
   `legacy_local_purge.v1.<purgedAt ISO-8601>` and sorted-keys JSON
   `{deleted, planToken, predicateVersion, purgedAt, sessionCount, sources}`.

Any thrown error rolls the whole transaction back.

**IPC** (both in `ServiceCapabilityToken.protectedCommands`; the preview is
protected because it discloses the plan token):

- `legacyLocalPurgePreview`, no payload: a `performReadCommand` (does not
  bump `databaseGeneration`) returning the report.
- `legacyLocalPurgeApply {expectedSessionCount, expectedPlanToken}`: exact
  keys, count >= 1, token 64 lowercase hex; a `performWriteCommand`
  classified as long-running (the FTS5 delete is a full scan). Purge errors
  map to `InvalidRequest`: `legacy local purge plan changed: sessions=N
  token=T`, `legacy local purge refused: user-state dependents k=v,...`,
  `legacy local purge has nothing to purge`, `legacy local purge
  verification failed`.
- Both refuse with `legacy local purge requires runtimeRole index` unless
  the service's startup role (read once by the runner, passed into
  `EngramServiceCommandHandler`) is `index`. The handler's default is
  `.local`, so a handler built without a role fails closed.

**CLI**: `EngramCLI maintenance legacy-local-purge preview [--json]` and
`EngramCLI maintenance legacy-local-purge apply --expect-sessions N
--expect-token HEX [--json]`, over the same socket resolution as
`EngramCLI archive`. Each flag at most once; anything else is a usage error
(exit 64). `--json` prints compact sorted JSON, otherwise pretty sorted JSON.

**Offline report**: `EngramService --legacy-local-purge-report
--database-path ABS` (exactly that argv) opens the file with a read-only
GRDB `DatabaseQueue`, prints the report as sorted pretty JSON and exits,
before any socket, lock, settings or migration work. A missing file is an
error and is not created.

## Invariants affected

- New: "Legacy Local-Origin Purge Is An Explicit Operator Action".
- Amended: "Legacy Host Scan Runs Only in the Local Role" now says the gate
  itself neither removes nor rewrites local-origin rows and names the purge
  as the only remover.
- #1 Single-Writer: the apply runs inside `ServiceWriterGate`; the offline
  mode is read-only and the CLI only speaks IPC.
- #2 (Subagent Sessions Stay Skip) and #10 (Manual Unlink Is Respected):
  preserved, because manual links and outside children block the purge, so
  `trg_sessions_parent_cascade` only touches rows that are deleted in the same
  statement.
- #5 (FTS Full Rebuild Versioning): `sessions_fts`, `fts_map` and
  `sessions_fts_rebuild` rows go in the same transaction as their sessions;
  the FTS version key is not touched.
- #6 (Tests Avoid Production Engram Data): every test uses a temp-directory
  database; no test opens the HQ database or a copy of it.
- Capture identity invariants: untouched; bound rows are excluded by the
  predicate and protected by the FK.

## Alternatives considered

- (a) Keep the rows: they keep duplicating capture rows for D4/D5 readers.
- (b) W4.1 same-host alias: needs its own design and provenance proof; D7
  chose (c).
- Raw SQL on the host: a second writer with no audit and no re-plan check.
- A count-only guard without a token: cannot detect a different set of the
  same size.
- Letting the offline mode purge: a second writer outside the gate.

## Test plan

- `macos/EngramCoreTests/Database/LegacyLocalSessionPurgeTests.swift`:
  `testReportCountsLegacyGrokPiRowsAndDerivedRowsExcludingCaptureBound`,
  `testReportFlagsEveryUserStateDependentAsBlocking`,
  `testPurgeRefusesWithUserStateDependentsAndChangesNothing`,
  `testPurgeRefusesChangedPlan`,
  `testPurgeClearsLegacyRowsAndDerivedRowsLeavingCaptureRowsUntouched_repro`,
  `testReportRunsOnReadOnlyConnection`.
- `macos/EngramServiceCoreTests/LegacyLocalPurgeIPCTests.swift`:
  `testLegacyLocalPurgeCommandsAreCapabilityProtectedAndApplyIsLongRunning`,
  `testLegacyLocalPurgeRefusesOutsideIndexRole`,
  `testLegacyLocalPurgePreviewThenApplyThroughWriterGate_repro`,
  `testLegacyLocalPurgeApplyRejectsMalformedPayload`,
  `testLegacyLocalPurgeReportFlagIsReadOnly`,
  `testParsesLegacyLocalPurgeCLICommands`.
  `ServiceSecurityHardeningTests` picks both commands up from
  `protectedCommands`.
- All fixtures are temp-directory databases. Not tested: the real HQ data,
  the HQ deploy and the apply on HQ, and launchd.

## Rollout

1. Merge. Nothing runs on its own: no startup path calls the purge.
2. Operator runbook, read-only for the live HQ database. It writes only a
   copy in a new 0700 scratch directory and never opens the live file for
   writing:

   ```sh
   SRC="$HOME/.engram-shadow-core-20260911/hq/state/service-index/database/index.sqlite"
   OUT="/private/tmp/d7-report-$(date -u +%Y%m%dT%H%M%SZ)"
   mkdir -m 700 "$OUT"
   # Online backup through SQLite; reads SRC only.
   sqlite3 -readonly "$SRC" ".backup '$OUT/index.sqlite'"
   # These PRAGMAs touch only the copy. Expect "delete" and "ok".
   sqlite3 "$OUT/index.sqlite" "PRAGMA journal_mode=DELETE; PRAGMA integrity_check;"
   ```

   Build the report binary from merged `main` on a development Mac (no HQ
   deploy needed):

   ```sh
   xcodebuild build -project macos/Engram.xcodeproj -scheme EngramService \
     -configuration Debug CODE_SIGNING_ALLOWED=NO
   BIN="$(ls -d ~/Library/Developer/Xcode/DerivedData/Engram-*/Build/Products/Debug | head -1)/EngramService"
   "$BIN" --legacy-local-purge-report --database-path "$OUT/index.sqlite" > "$OUT/report.json"
   ```

   Expected from the 2026-10-17 counts (UNVERIFIED until run):
   `sessionCount` about 6,191 (grok about 5,959, pi 232),
   `captureBoundExcluded` 0, `otherLocalOriginSessions` `{}`, every
   `blocking` value 0, `purgeAllowed` true, `derived` non-zero at least for
   `sessionsFts`, `ftsMap` and `sessionIndexJobs`, `retained` reported.

   Cross-check independently on the copy:

   ```sh
   PRED="FROM sessions s WHERE s.source IN ('grok','pi') \
     AND COALESCE(NULLIF(TRIM(s.origin),''),'local')='local' \
     AND COALESCE(NULLIF(TRIM(s.authoritative_node),''),'local')='local' \
     AND s.id NOT LIKE 'remote:%' \
     AND NOT EXISTS (SELECT 1 FROM capture_ingest_identity_bindings b WHERE b.stored_session_id=s.id) \
     AND NOT EXISTS (SELECT 1 FROM capture_ingest_generations g WHERE g.stored_session_id=s.id)"
   sqlite3 -readonly "$OUT/index.sqlite" "SELECT source, COUNT(*), MAX(indexed_at) $PRED GROUP BY source;"
   (printf 'engram-legacy-local-purge-v1\n'; sqlite3 -readonly "$OUT/index.sqlite" "SELECT s.id $PRED ORDER BY s.id;") \
     | shasum -a 256
   ```

   The per-source counts must equal `report.json` `sources` and the digest
   must equal `planToken`.
3. The owner reviews `report.json` (`sessionCount`, `planToken`, `blocking`,
   `derived`, `retained`) and approves the token and count, or decides on any
   non-zero blocking key (see open questions).
4. The owner deploys the current service-index and EngramCLI to HQ
   (mutation; HQ's service-index was `8a6cdf6c`, 67+ commits behind, on
   2026-10-17).
5. Live preview:
   `ENGRAM_SERVICE_SOCKET=<central socket> EngramCLI maintenance legacy-local-purge preview --json`.
   Its `planToken` and `sessionCount` must equal the approved ones; otherwise
   go back to step 2.
6. Take a fresh rollback copy with `sqlite3 -readonly "$SRC" ".backup ..."`
   immediately before the apply, then run
   `EngramCLI maintenance legacy-local-purge apply --expect-sessions N --expect-token T --json`.
7. Post-checks: preview again shows `sessionCount` 0; `SELECT value FROM
   metadata WHERE key = '<auditKey>'` returns the audit JSON.

Revert: restore the pre-apply backup taken in step 6 (service stopped). The
code revert is removing the two commands; there is no schema to undo.

## Risks and open questions

- HQ runs an old service-index, so the live commands exist only after an
  owner-run deploy; until then the offline backup-copy report is the only
  source.
- Any legacy row added, removed or newly bound between the approved report
  and the apply makes the apply fail closed with "plan changed"; a second
  approval round may be needed. This is intended.
- The `sessions_fts` delete is a full scan of the FTS5 table and holds the
  writer gate (long-running classification); capture ingest commits queue
  behind it.
- Freed pages stay in the file until a later owner-scheduled `VACUUM`
  (out of scope).
- `file_index_state` rows for purged grok/pi locators are kept and
  reported. They are harmless on an index host, but if HQ were ever switched
  back to the `local` role, those `ok` states could stop the legacy scan from
  re-creating the rows. Whether to clear them is an open question.
- Outside suggested children (advisory `suggested_parent_id`) block the
  purge, the conservative reading of "only if the dependent count is zero".
  If the real report shows some, the owner decides between keeping the rule
  and narrowing it.
- `fileIndexState` matches a candidate's `file_path` or `source_locator`; it
  is informational and was not checked against real HQ grok/pi rows.
- A read-only open of a WAL-mode file can create `-shm`/`-wal` side files;
  the runbook switches the copy to `DELETE` journal mode first so this only
  ever touches the copy.
