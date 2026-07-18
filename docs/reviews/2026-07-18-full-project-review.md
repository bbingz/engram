# Engram Full-Project Review — 2026-07-18

**Branch reviewed:** `fix/audit-2026-07-17-batch-h-m14-m15-closeout`  
**Method:** Six parallel read-only domain experts (service/write, MCP/app reads, security, UI/adapters/archive, tests/CI/docs, architecture), then orchestrator synthesis against live source.  
**Context:** Post 2026-07-17 audit closeout multi-PR stack (#188–#195 lineage).

## Executive summary

Engram is in **strong product health** for a local-first Swift app. The write path (single-writer gate, migrations, Archive V2 CAS, project-move compensation) and cross-user local isolation remain the strongest layers. The 2026-07-17 audit closeout **credibly fixed the named Highs and most defect Mediums** with substantial real-path tests.

This review is **not** a re-run of that audit from zero. It answers: *after the fix stack, what is the whole project’s state?*

| Grade | Area |
|-------|------|
| **A** | Write path, Archive V2 integrity, IPC cross-user isolation, Swift product authority |
| **B+** | Audit closeout of H1/H2/SEC-H1/H2/M18/M19/M24 (primary paths) |
| **B** | Adapters (counts/sidecar/tail API better; product tail merge still dead) |
| **C+** | Read-surface parity (still three SQL stacks — structural residual) |
| **C** | Closeout docs/evidence ledger quality; PR stack merge hygiene |
| **B** | CI product path (M11 hygiene real); public release/notarization still ops lag |

**No critical findings.** Highest post-merge priorities: (1) public release baseline, (2) one structural investment in shared read predicates / parity suite, (3) streaming JsonlPatch false-match at chunk cut if project-move still ships multi-hundred-MB files.

---

## What’s healthy (keep)

1. **Swift product authority** with mechanical gates (no app/MCP direct CoreWrite, bundle hygiene, module boundaries).
2. **Single-writer + Archive V2 + ProjectMove** integrity engineering (fsync/rename, dual-receipt reclaim, LIFO compensation).
3. **Security cross-user model:** 0700 runtime, 0600 socket, peer euid, capability token on all mutators, project path confinement.
4. **Landed audit fixes (spot-verified on HEAD):** H1 GROUP BY, H2 `keywordSearchLike`, M1 `pendingOrActiveLongWrites`, SEC-H1 bare-label ban + default TLS on, SEC-H2 secrets scrub, SEC-M2 `O_NOFOLLOW`, M14 `hasObject`/`hasManifest`, M23 sidecar validation, M20 `AISettingsURLValidation`.
5. **Strong real-path repros** for many items: MCP CJK/H2, M9/M18/M19/M24 RPC fixtures, M12 boundary hit, H1 projects window, M5 KPI aggregates, SEC token matrix + peer/socket 0600.
6. **Clear dual-language tax:** TS is reference/fixtures, not product runtime.

---

## Prioritized findings (synthesized)

Severity is for **current HEAD after audit closeout**, not pre-audit.

### High

#### R1. Triple read surfaces — structural residual (still the #1 architecture risk)

**Where:** `Database.swift` · `MCPDatabase.swift` · `EngramServiceReadProvider.swift`  

**Claim:** Concrete defects (H1/H2/M18/M19/M24 primary paths) are fixed, but the **cause** (three independent SQL implementations) remains. Shared helpers (`HumanDrivenFilter`, `CJKText`, searchable-tier SQL) are incomplete coverage.  

**Evidence of ongoing drift (new/leftover):**

| Invariant | App | Service | MCP |
|-----------|-----|---------|-----|
| Multi-term FTS (session-scoped AND) | CTE per term | CTE per term | single MATCH per row |
| Search `since` | `COALESCE(end_time,start_time)` | same | `start_time` only |
| Project filter | exact / IN | exact | `LIKE %…%` |
| Aggregates exclude skip | KPI yes; `countSessionsSince` **no** | — | `stats` includes skip |
| `orphan_status` filter | no | no | yes |

**Fix:** Shared predicate builders under `EngramCore` / thicken CoreRead, **or** one cross-surface parity fixture suite. Delete incomplete private `containsCJK` in MCP if still present beside `CJKText`.

---

#### R2. Streaming JsonlPatch can false-match at chunk ends (`$` lookahead)

**Where:** `JsonlPatch.swift` `pathTerminatorLookahead` + streaming carry  

**Claim:** Carry keeps `pathLen+8` bytes, so straddling **hits** are tested (M12 boundary repro passes). End-of-segment `$` can still treat incomplete tokens as terminators when the next byte is a non-terminator (`-`, `_`), rewriting longer paths on **>128 MB** streaming files.  

**Fix:** Do not treat EOS as terminator mid-stream; only on final carry. Add negative repro (needle + non-terminator across cut must not rewrite).

---

### Medium

#### R3. M5 only partially closed outside KPI charts

`countSessionsSince` (Activity today/week), `sourceStats` / some list helpers, MCP `stats` session counts still include skip-tier. Same-page UI can disagree (charts vs “today” counters).

#### R4. M3 incomplete for **insight** embeddings

Session embedding path has per-job terminal state; insight path remains all-or-nothing batch + reselect forever on poison content.

#### R5. Reclamation cursor still skips eligibles when **byte budget** binds

M4 fixed count-cap advance; budget-skipped candidates still advance cursor past them.

#### R6. Project-move holds writer gate for entire FS+patch lifetime

M1 prevents false timeouts; availability still queues all writes behind long moves.

#### R7. Offload HTTP client weaker than Archive V2 (residual SEC-H1)

Bare labels blocked; default `requireTLS=true`. Still `URLSession.shared`, no redirect reject / size caps / post-DNS private check. Comment still says product default OFF (stale).

#### R8. Codex content tail indexing is dead in product

Adapter tail API + tests exist; `mergeTailSnapshot` always returns `nil` → full reparse on any real append.

#### R9. AI settings debounce can drop last edits (M21 residual)

No flush on disappear; MainActor I/O after debounce remains.

#### R10. M14 test is source-grep theater (fix likely real)

`hasObject`/`hasManifest` wired in production; sole M14 `_repro` only greps sources. Need PUT→HEAD behavioral test.

#### R11. Disposition is a status table without evidence columns

`fixed=37 residual=40 pending=0` without test/PR per row; residuals doc self-contradicts (`pending-fix` vs accepted). Residuals not promoted to `docs/followups.md` / `TODO.md`.

#### R12. Multi-PR stack merge risk (#188–#195)

Parallel themed PRs without a reconciliation memo → last-merge-wins on docs, rebase debt before green `main`.

---

### Low / Info

| ID | Summary |
|----|---------|
| L-a | MCP search min length / multi-word recall vs app |
| L-b | Gemini tool counts always 0; type filter narrow |
| L-c | Timeline only reacts to `totalSessions`, not content |
| L-d | Archive Sync refresh fails silent; no poll while open |
| L-e | Warp tab config without forced 0600 (short-lived) |
| L-f | DerivedData Release can still plaintext settings keys |
| L-g | `get_context` “Cost today” UTC vs get_costs local |
| L-h | Public release lag (eng 1.0.4 vs GH v1.0.3) / notarization manual |
| L-i | ~30 lows residual without backlog home |
| L-j | TS `safeMoveDir` still lacks case-only exception (reference only) |

---

## Security posture (post-audit)

| Actor | Practical risk |
|-------|----------------|
| Other local user | Well contained (0700/0600/euid/token) |
| Same-user / MCP | Trusted peer by design (SEC-M5/I1) |
| Network → Archive | Strong client; cleartext Tailscale when `requireTLS=false` (SEC-M4 ops) |
| Network → Offload HTTP | Weaker than Archive; improved defaults but shared URLSession residual |

No new critical/high security defects found beyond documented residuals.

---

## Test strategy assessment

| Grade | Pattern |
|-------|---------|
| **Strong** | MCP executable + fixture (H2, M9/M18/M19/M24), JsonlPatch multi-MiB boundary hit, H1 projects, M5 KPI, SEC matrix |
| **Weak** | M14 HEAD source-grep, M21 debounce source-grep, disposition without evidence map |
| **CI** | M11 hygiene structural real-exec is good; Debug≠Release packaging caveat |

---

## Verdict

| Question | Answer |
|----------|--------|
| Safe to treat write/integrity core as production-ready? | **Yes** |
| Safe to claim 2026-07-17 Highs closed? | **Yes** (H1/H2/SEC primary paths + tests) |
| Safe to claim all Mediums fully closed? | **No** — M5 partial, M3 insights, M4 budget, M12 false-match, M21 residual, M14 under-tested |
| Biggest architecture debt after merge? | **Triple read SQL** |
| Best next product move? | **Ship public release baseline (v1.0.5)** then one read-parity investment |

**Overall:** **APPROVE for merge-to-main *as integrity-ready engineering*** with explicit follow-ups for R1–R3. Do **not** treat disposition “fixed=37” as equivalent verification depth for every row.

---

## Recommended next actions (priority order)

1. **Release baseline** — green main → notarize/staple/smoke (product owner path).  
2. **R1** — shared list/search/cost predicates or cross-surface parity tests.  
3. **R2** — JsonlPatch streaming terminator without mid-stream `$`.  
4. **R3/R4/R5** — finish M5 counters, insight embed lifecycle, reclamation budget cursor.  
5. **R10/R11** — behavioral M14 test; disposition evidence columns; promote residuals to followups.  
6. **R7** — optional Archive-parity transport for offload HTTP.  
7. Leave SEC-M5/I1/I2/M15 as documented design/ops debt unless product-hot.

---

## Expert roster

| # | Angle | Outcome |
|---|-------|---------|
| 1 | Service / write / embed / ProjectMove | 9 findings; M1/M2 solid; M3 insights open; JsonlPatch false-match high |
| 2 | MCP / app reads | 12 findings; H1/H2/M18/M19/M24 primary OK; multi-term/since/project drift |
| 3 | Security | 0 critical/high new; residual offload transport + same-user model |
| 4 | UI / adapters / archive | 0 high; timeline signal, dead tail merge, debounce drop |
| 5 | Tests / CI / docs | M14 theater; disposition weak; M11 strong; stack risk |
| 6 | Architecture / product | Ship-ready integrity; triple-read + release lag |

*Orchestrated 2026-07-18. Review only — no code changes in this document’s production of findings.*
