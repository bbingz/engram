# Engram Multi-Expert Audit — 2026-07-10

Fresh full-product review of `main` at **`a011e2fb`** (clean working tree),
orchestrated as a multi-expert audit after wave-5 and wave-6 landed (tail-parse,
diagnostic bundle, MCP semantic/hybrid, embedding circuit breaker, FTS optimize
cadence, quality-score single source, sessions filter persistence, originator
ordering, and related fixes).

This review is independent of prior documents but deliberately checks whether
historical findings remain open on current source.

## Method

| Step | Detail |
|------|--------|
| Mode | Multi-expert audit (orchestrator + 8 parallel read-only domain experts) |
| Experts | Service runtime/IPC · Indexing/FTS · Semantic/embeddings · MCP surface · Parent/tiering · SwiftUI/UX · Security/integrity · Test/CI/docs |
| Constraints | Read-only; no edits; cite `file:line` + verbatim evidence; max ~12 findings each |
| Adjudication | Cross-expert dedupe; adversarial re-open of every critical/high on live source by the orchestrator |
| Round-2 | Not re-run as full sweep; critical/high paths re-read in source during synthesis |
| Out of scope for this round | Fix implementation, product-decision backlog items already parked in `docs/roadmap.md` |

### Expert scoreboard

| # | Angle | Score | Raw findings |
|---|-------|-------|--------------|
| 1 | Service runtime / IPC / writer gate | concerns | 11 (1 historical closed) |
| 2 | Indexing / FTS / quality / tail-parse | concerns | 10 (1 critical) |
| 3 | Semantic / embeddings / hybrid | concerns | 10 |
| 4 | MCP surface / contracts | concerns | 9 |
| 5 | Parent linking / tiering | concerns | 9 (+1 solid order lock) |
| 6 | SwiftUI / UX | concerns | 12 |
| 7 | Security / integrity | concerns | 10 |
| 8 | Test / CI / docs drift | concerns | 12 |
| | **Total raw** | | **~83** |
| | **After dedupe (this report)** | | **42 confirmed** |

Severity after merge: **critical 1 · high 12 · medium 20 · low 9**.

No remote unauthenticated surface reintroduced (HTTP transcript Web UI remains
deleted). Overall product grade: **concerns** — wave-5/6 closed many prior
holes, but indexing stamp poison, skip-tier lifecycle leaks, and
advertised-vs-runtime drift remain high impact.

---

## What improved since 2026-06-10 (closed / not re-opened)

| Historical theme | Status on `a011e2fb` |
|------------------|----------------------|
| Whole-frame 30s deadline vs 600s project migrations | **Fixed** — `frameDeadline` uses `max(30s, requested)` (`UnixSocketEngramServiceTransport`) |
| Breaker half-open wedge on non-transport failures | **Fixed** — `recordNonTransportFailure` + recovery tests |
| Wave-6 originator before suggested-parent scoring | **Fixed and test-locked** |
| MCP semantic over-advertised without vectors | **Solid** — tools/list gated; unavailable → hard error |
| Mutating MCP tools write SQLite directly | **Solid** — read-only DB + service gate |
| Subagent always-skip + setParent does not upgrade tier | **Solid** for confirmed links |
| FTS throw-safe optimize cadence | **Solid** — attempt stamp before rewrite |
| SessionQualityScore single source | **Solid** for incremental path |
| Socket peer-UID + capability token on mutators | **Solid** (same-UID trust model) |

Residual timeout pain is no longer the migration frame cap; it is **writer-gate
queue vs long index holders** and **short AI-bound RPCs** (see H02–H03).

---

## Systemic patterns

1. **Index identity stamping without content update** — startup and active-file
   grace record `file_index_state` success at the *current* mtime/size while
   skipping parse; later decisions treat the file as fully indexed (C01, M03).
2. **Skip-tier lifecycle leaks for non-subagent agents** — ambiguous suggestions
   and parent-delete cascade clear `tier` for `dispatched` sessions that should
   stay hidden (H04, H05).
3. **Dual-path semantic policies without dual honesty** — MCP hard-fails;
   service soft-falls-back to keyword; app UI claims “no vector path” while
   service/MCP implement embeddings (H07, H08, M07–M09).
4. **Timeout / cancel asymmetry** — client budgets can expire while the service
   keeps mutating disk/DB (`generateSummary`, `linkSessions`, project batch)
   (H02, H03, M05).
5. **Docs and annotations lag runtime** — README, AISettings comments,
   `SearchModeTests`, `list_sessions` docs, `generate_summary` `readOnlyHint`
   (H06, H08, M10–M12).
6. **Same-UID local trust is solid; secret/path hygiene still incomplete** —
   memory-file bounds, embedding key Keychain/redaction, settings 0600 on
   service rewrite (H09, M13–M15).

### Hotspots

`macos/EngramCoreWrite/Indexing` · `macos/EngramService/Core` ·
`macos/Shared/EngramCore/AI` · `macos/EngramMCP/Core` · parent backfills +
top-level UI filters · app search/settings honesty

---

## Confirmed findings — CRITICAL (1)

### C01. Startup `skipKnownFileLocators` stamps success on grown files without reindex

- **Severity:** critical · **Confidence:** high
- **Found by:** Indexing/FTS · **Verified:** orchestrator re-read
- **Location:** `macos/EngramCoreWrite/Indexing/SwiftIndexer.swift:224-230`
- **Related:** `FileIndexDecision` skip on `.ok` —
  `IndexingWriteSink.swift:95-98`; periodic loop first tick after 5 min sleep —
  `EngramServiceRunner.swift:335-339`

**Evidence:**

```swift
if skipKnownFileLocators {
    try recordFileIndexSuccess(source: adapter.source, locator: locator, stat: currentStat)
    continue
}
```

**Why it matters:** Offline growth → restart records the new identity as
indexed without updating `sessions`/FTS. Periodic `indexRecentSessions` then
also `.skip` until another mtime/size change. No FSEvents watcher; first
recovery tick is delayed. Tests require startup *not* to reparse known modified
files (`testStartupIndexAllSkipsKnownModifiedFileLocators`) but do not assert
later recovery of content — the stamp makes recovery fail.

**Recommendation:** When deferring known locators, **do not** rewrite
`file_index_state` to the new identity (leave dirty/old state), or mark a
retryable dirty status and enqueue reindex without full startup cost.

---

## Confirmed findings — HIGH (12)

### H01. FTS rebuild finalizes with permanent/N/A failures omitted from swapped table

- **Severity:** high · **Confidence:** high
- **Found by:** Indexing/FTS
- **Location:** `FTSRebuildPolicy.swift:374-383` (only waits
  `pending`/`failed_retryable`); `IndexJobRunner.swift:210-214` (terminal FTS
  failure → `not_applicable` then `finalizeRebuildIfReady`)

Pre-existing `failed_permanent` jobs are never reopened on rebuild start
(only `completed` → `pending`). After swap, those sessions can permanently
lose keyword rows until a later content-driven re-enqueue.
`enqueueStaleFtsJobs` only resurrects sessions that already had a **completed**
FTS job (compounds).

**Recommendation:** Do not finalize while any non-skip session lacks rebuild
content; reopen permanent failures or copy live rows into shadow for terminals.

### H02. Multi-minute index/backfill holds are not “long-running” → 60s WriterBusy

- **Severity:** high · **Confidence:** high
- **Found by:** Service runtime
- **Location:** `ServiceWriterGate.swift:89-91`, `:204-214`

Only `projectMove*`, `remoteVacuum`, `userDataBackup` disable follower
timeouts. `initialScanIndex`, backfills, `indexRecent`, FTS drain, embedding
writes hold the gate under the **60s** queue timeout → healthy progress looks
like wedge to concurrent user writes.

**Recommendation:** Mark index/backfill/FTS/embed phases long-running, or batch
them hard enough that 60s is never a false busy.

### H03. `generateSummary` / `linkSessions` client 25s budgets vs long server work

- **Severity:** high · **Confidence:** high
- **Found by:** Service runtime
- **Location:** `EngramServiceClient.swift` `frameBoundCommandTimeout = 25`;
  AI HTTP also 25s; `linkSessions` up to 10k symlink ops outside the gate

Client can report failure while the service persists summary or continues
creating symlinks (partial disk mutation).

**Recommendation:** Leave headroom (AI timeout &lt; client timeout); honor
cancellation between link iterations; or stream/batch.

### H04. Ambiguous suggestions un-skip `dispatched` agents into top-level lists

- **Severity:** high · **Confidence:** high
- **Found by:** Parent/tiering · **Verified:** orchestrator
- **Location:** `StartupBackfills.swift:1728-1741` (`setAmbiguousSuggestion`
  clears `agent_role`/`tier` for dispatched+skip); top-level filter only
  `parent_session_id IS NULL AND suggested_parent_id IS NULL`
  (`Database.swift:180-181`) — ignores `suggestion_status`

Near-tie agent sessions reappear as normal top-level work while also listed
under Ambiguous. Tests lock “WithoutSkipping” behavior without aligning UI
filters.

**Recommendation:** Keep skip on ambiguous, **or** exclude
`suggestion_status = 'ambiguous'` from all top-level queries.

### H05. Parent-delete cascade / `clearParent` drops skip for `dispatched`

- **Severity:** high · **Confidence:** high
- **Found by:** Parent/tiering
- **Location:** `EngramMigrations.swift:84-94` (trigger keeps skip only for
  `agent_role = 'subagent'`); `clearParentSession` mirrors

`dispatched` keeps role but `tier = NULL` until re-index → temporarily
searchable/listable noise. Cascade tests only assert subagent preserve.

**Recommendation:** Keep `tier = 'skip'` when
`agent_role IN ('subagent','dispatched')` (or any non-null agent role).

### H06. `generate_summary` advertised `readOnlyHint: true` but mutates DB

- **Severity:** high · **Confidence:** high
- **Found by:** MCP surface · **Verified:** orchestrator
- **Location:** `MCPToolRegistry.swift:1223-1224` (`.longRunningRead` →
  `readOnlyHint: true`); service writes summary
  `EngramServiceCommandHandler.swift:1383-1394`

Clients that auto-approve read-only tools will treat a write as safe. Docs
correctly say it updates the DB; annotations disagree.

**Recommendation:** Classify as `.mutating`; add annotation regression test.

### H07. Query embedding model not validated against stored model (same-dim swap)

- **Severity:** high · **Confidence:** high
- **Found by:** Semantic/embeddings
- **Location:** MCP dim-only check `MCPDatabase.swift:974-1005`; service
  embeds then filters candidates by meta model without requiring query model
  equality (`EngramServiceReadProvider.swift:631-639`, `704-729`)

Same-dimension model swap → confident wrong ranking. Design claims never mix
models; enforcement is incomplete on the **query** side.

**Recommendation:** Fail closed unless `config.model` (+ dim) matches
`embedding_meta`; rebuild or refuse on mismatch.

### H08. App UI / tests / settings claim “no Swift vector path” while service+MCP implement it

- **Severity:** high · **Confidence:** high
- **Found by:** Semantic + Test/CI/docs (merged)
- **Location:** `SearchSupport.swift:6-11`; `SearchModeTests.swift:11-18`;
  `AISettingsSection.swift:13-18`; `README.md` semantic degrade claims

Service has `semanticSearch` + guarded embeddings; MCP has task-10 hybrid.
App keyword-only may be an intentional non-goal; the **stated reason** and
README degrade story are false (MCP hard-errors; service falls back).

**Recommendation:** Truth-up copy/tests: “App UI intentionally keyword-only;
service/MCP semantic when embeddings usable.” Align README MCP vs service
policies in one paragraph.

### H09. `memoryFileContent` confinement incomplete (symlink / non-`memory/` .md)

- **Severity:** high · **Confidence:** high (same-UID)
- **Found by:** Security · **Verified:** orchestrator
- **Location:** `EngramServiceReadProvider.swift:169-183`

Comment claims `~/.claude/projects/*/memory`; check is only prefix under
`~/.claude/projects` + `.md` + regular file. No realpath / symlink refusal;
`String(contentsOf:)` follows links. Not capability-token gated.

**Recommendation:** Require realpath under `.../memory/`, reject symlinks,
token-gate or keep read-only with strict path tests.

### H10. `snapshotHash` / `searchText` ignore message body

- **Severity:** high · **Confidence:** high
- **Found by:** Indexing/FTS
- **Location:** `SwiftIndexer.swift:720-732`; `SessionSnapshotWriter.swift:123-128`, `:826-828`

Same-count rewrites / in-place stores with stable summary leave FTS stale
(append-only JSONL mostly fine).

**Recommendation:** Content fingerprint, or force `searchTextChanged` when
size/locator identity changes even if hash matches.

### H11. Command palette: service-down + empty local FTS → false “Search unavailable”

- **Severity:** high · **Confidence:** high
- **Found by:** SwiftUI/UX
- **Location:** `CommandPaletteView.swift:327-347` vs `SearchPageView` double-fault logic

Real no-match offline is shown as infrastructure failure.

**Recommendation:** Match Search page: empty local results are empty, not fail.

### H12. Command palette export replaces the whole results pane; no in-flight state

- **Severity:** high · **Confidence:** high
- **Found by:** SwiftUI/UX
- **Location:** `CommandPaletteView.swift:121-125`, `:282-294`

User loses selection context; long export looks finished or blank. Aligns with
open perceived-duration followup for export.

**Recommendation:** Status banner + keep list; in-progress + Finder reveal parity.

---

## Confirmed findings — MEDIUM (20)

| ID | Title | Expert | Location (primary) |
|----|-------|--------|--------------------|
| M01 | `performWriteCommand` bumps `databaseGeneration` on pure reads | Service | `ServiceWriterGate.swift:94-102` |
| M02 | Initial-scan telemetry records scan even when phases failed | Service | `EngramServiceRunner.swift:648-668` |
| M03 | Active-file grace stamps success without indexing | Indexing | `SwiftIndexer.swift:232-234` |
| M04 | Tail parse failures never fall back to full reparse in-pass | Indexing | `SwiftIndexer.swift:208-219` |
| M05 | Project batch cancel disabled; client cancel ≠ service stop | UX / followups | `BatchMoveSheet.swift:161-163` |
| M06 | Service semantic soft-fallback warning is one-size-fits-all | Semantic | `EngramServiceReadProvider.swift:482-507` |
| M07 | `get_memory` hybrid fail mislabels “No embedding provider” | Semantic | `MCPDatabase.swift:465-483` |
| M08 | MCP session search has no embedding circuit breaker | Semantic | `MCPDatabase.swift:982-986` |
| M09 | Semantic KNN recency-capped (not full corpus) | Semantic | `SessionSemanticSearchPolicy.candidateCap` users |
| M10 | `list_sessions` docs claim `noiseFilter`; runtime is human-driven + `include_all` | MCP + Docs | `docs/mcp-tools.md` vs `MCPDatabase.swift:152-160` |
| M11 | `get_session.roles` docs “all roles” vs user/assistant default | MCP | `docs/mcp-tools.md` vs `MCPTranscriptReader` |
| M12 | `export` loses `transcriptTooLarge` structured code | MCP | `TranscriptExportService.swift:27-28` |
| M13 | `embeddingApiKey` not Keychain-migrated; `@keychain` skipped | Security | `EmbeddingSettings.swift:17-36` |
| M14 | Diagnostic redaction misses `embeddingApiKey` | Security | `DiagnosticBundleComposer.swift:88-96` |
| M15 | Service settings write does not force 0600 | Security | `EngramServiceCommandHandler.swift:1010-1016` |
| M16 | MCP/`get_session` transcripts unredacted; export redacted | Security | `MCPTranscriptTools` vs `TranscriptExportService` |
| M17 | `dismissSuggestion` not sticky (`link_source` not `manual`) | Parent | `EngramServiceCommandHandler.swift:753-768` |
| M18 | Polycli concurrent path can false-skip ordinary same-cwd sessions | Parent | `StartupBackfills.swift:1408-1448` |
| M19 | Browse favorites add-only; Starred list removes toggle | UX | `ExpandableSessionCard` / `SessionsPageView` |
| M20 | README overclaims value bands on session lists | Docs | `README.md` vs `SearchPageView` only |

---

## Confirmed findings — LOW (9, selected)

| ID | Title |
|----|-------|
| L01 | Unescaped stdout fatal JSON interpolation (`EngramServiceRunner`) |
| L02 | `serviceLogs` silently drops bad payload (`try?`) |
| L03 | Status stays `.starting` until first fully successful scan |
| L04 | Quality score backfill never rewrites non-zero scores after formula drift |
| L05 | FTS job stream can complete after 10k message truncation |
| L06 | `project_review` tools/list says “7” roots; scanner has 10 |
| L07 | `get_memory` type filter works but type not in structured payload |
| L08 | `LiveSessionCard` still uses fractional-only ISO parser |
| L09 | Invariant ledger CI is path-existence only; nightly perf has no threshold |

---

## Docs claim checks (orchestrator table)

| Claim | Reality | Verdict |
|-------|---------|---------|
| README: MCP semantic → keyword + warning | MCP hard-error `searchModeUnavailable` | **False** |
| README: no embedding / KNN path | Service + MCP brute-force cosine when usable | **False** |
| `docs/mcp-tools.md`: unavailable semantic hard-error | Matches MCP | **True** |
| `docs/mcp-tools.md`: 27 tools | Matches registry + tests | **True** |
| Roadmap: value-band badge on cards not done | Search-only bar | **True** |
| AISettings: embeddings not implemented | Runtime stack present; UI removed | **False comment** |
| Wave-6 FTS optimize / breaker / quality / tail-parse tested | Named Swift tests present | **True** |
| Historical 30s vs 600s migration frame | Fixed via `frameDeadline(max)` | **Closed** |

---

## Prioritized remediation backlog

### P0 — correctness / data integrity (next wave)

1. **C01** — stop stamping `file_index_state` success without reindex on startup skip.
2. **H01** — FTS rebuild completeness for permanent/N/A failures.
3. **H04 + H05** — stop skip-tier leaks for ambiguous + cascade/clearParent on `dispatched`.
4. **H10** — FTS change detection when body changes without metadata hash change.

### P1 — trust, contracts, timeouts

5. **H06** — `generate_summary` mutating annotation.
6. **H02 + H03** — writer-gate long holders + AI/link RPC budgets / cancel.
7. **H07** — embedding model+dim integrity at query and write.
8. **H09 + M13–M15** — memory path bounds + embedding secret hygiene.
9. **H08 + M10** — truth-up README / app comments / `list_sessions` docs.

### P2 — UX / polish

10. **H11 + H12** — command palette search/export honesty.
11. **M17 + M18** — sticky dismiss; tighten Polycli admission.
12. **M05 + open followups** — export progress; migration cancel/background.
13. **M19 + L08** — favorites toggle; remaining timestamp helpers.

### P3 — gates / hygiene

14. **L09** — invariant ledger beyond path-existence; perf baseline or explicit observe-only label.
15. **M01–M02** — generation bump on reads; failed-scan telemetry honesty.
16. Privacy/Security doc refresh for embeddings, socket auth, TLS defaults.

---

## Solid areas (do not regress)

- Unix socket trust stack: 0700/0600, peer euid, capability token on mutators, frame size/deadlines.
- Single-writer `ServiceWriterGate` + process flock; project-move HOME confinement.
- MCP write fail-closed without service; semantic tools/list gating + hard-error goldens.
- Shadow FTS rebuild dual-write; throw-safe optimize cadence; Claude tail safety gates.
- Wave-6 parent backfill order (originator → polycli → suggest) test-locked.
- `setParentSession` / `confirmSuggestion` do not upgrade tier.
- Sessions filter `@AppStorage` persistence; reduce-motion helpers; many wave-5/6 behavioral tests are non-tautological.
- DB file 0600 enforcement; export path confinement + content redaction (export path only).

---

## Method notes / limitations

- Experts were parallel explore agents; synthesis re-verified all critical/high
  citations against source on `a011e2fb`.
- Medium/low items are expert-backed with file evidence but not every line was
  re-executed in a second adversarial lens; treat medium as **confirmed
  candidates** ready for fix tickets or a deeper round-2 if contested.
- No production DB / live index corpus was measured in this pass (FTS size,
  rebuild duration, WriterBusy incidence remain unquantified).
- Product-decision items (lifecycle multi-factor score, BM25/CJK, Claude plugin,
  Homebrew/Sparkle, etc.) stay in `docs/roadmap.md` Decision pending — not
  re-litigated here as defects.

---

## Suggested next actions

1. Open a remediation plan (wave-7) from **P0 only** with TDD repros for C01,
   H01, H04/H05, H10.
2. Parallel small PR for **H06 + H08 docs/annotations** (low risk, high trust).
3. Optional round-2 deep-dive only if P0 tickets need design: indexing stamp
   policy, FTS rebuild finalize contract, agent skip lifecycle matrix.

---

*Orchestrator: multi-expert-audit skill · 8 parallel domain experts · HEAD
`a011e2fb` · 2026-07-10*
