# Wave 7 Engineering-Zero Closeout — 2026-07-10 (Round 4 durable truth)

**Program:** Close Wave 7 residual-open rows and reconcile backlog truth
**Plan:** `docs/superpowers/plans/2026-07-10-wave7-engineering-zero-closeout.md` Task 6
**Base HEAD (implementation complete):** `c983a759` (merge: wave8d long project operations)
**This closeout branch:** `bbingz/wave8f-engineering-zero-docs` (docs only)
**Primary ledger:** `docs/reviews/2026-07-10-wave7-remediation-closeout.md`

## Scope of this document

This file is the residual ledger for the 19 Wave 7 rows that were still
residual-open after Wave 7, plus the durable backlog reconciliation that
produces engineering-zero **backlog/ledger truth**.

It does **not** claim Task 7 final CI / CodeQL / release / install / runtime
smoke on a single SHA. Those gates remain for an independent Codex pass.

## Engineering zero vs roadmap zero

| Surface | Terminal claim after this closeout |
|---------|-------------------------------------|
| Wave 7 audit ledger | **43 terminal / 0 partial / 0 unadjudicated** |
| Engineering TODO (`docs/TODO.md`) | **0 open** |
| Engineering follow-ups (`docs/followups.md`) | **0 open implementation-ready items** |
| Roadmap decision-pending rows | **12 visible** — product decisions, **not** engineering defects |
| Final CI + release + runtime (Task 7) | **Not claimed** by this docs-only commit |

Roadmap decisions do **not** block engineering-zero backlog truth. They block
only product scheduling, not defect closure.

## Locked product contracts (Round 0)

| Decision | Contract adopted |
|----------|------------------|
| **M09** semantic eligibility | Full eligible corpus in cancellable GRDB batches with constant-memory top-K. Recency is **not** an eligibility filter. Latency is telemetry only. |
| **M16** transcript redaction | MCP transcript reads use the same default redaction policy as export. Raw content requires explicit `include_raw` and remains local-only. |

## Wave 8 merge evidence (implementation already on main)

| Round | Merge SHA | Scope closed |
|------:|-----------|--------------|
| 1B secret hygiene | `6fe46fd7` (tip `d90aad5f`) | M13, M14, M15 |
| 1A semantic integrity | `bdc95157` (tip `90b70690`) | H07, M06, M07, M08, M09 |
| 2A MCP/transcript | `130ed361` (tip `19c3ece9`) | M11, M12, M16, L06, L07 |
| 2B export/favorites | `262d59a2` (tip `cfed29b5`) | H12, M19 |
| 3B telemetry/gates | `c87fab56` (tip `f1486c2f`) | M02, L01, L02, L09 + disk-audit E2E |
| 3A long operations | `c983a759` (tip `eeab26a8`) | long-migration cancel/reconnect follow-up |

Coordinator-recorded focused verification (per-lane worker reports; not re-run
by this docs task):

- 1A: Core 6/6, Service 7/7, MCP focused green (incl. model-mismatch + full-corpus)
- 1B: Core 13/13, Service 5/5, Diagnostic 5/5, Settings 20/20, Launcher 16/16
- 2A: MCP 122/122, export 2/2
- 2B: CommandPalette 12/12, SessionModel 25/25, BrowseReload 8/8, SourceScan 52/52
- 3B: Service telemetry/log/IPC focused suites + invariant Vitest + bash ledger runner
- 3A: ProjectMove Core/Service/App focused suites after serial coordinator verification

## Residual ledger (19 rows)

Columns match the zero-closeout plan residual set.

| ID | Current source proof | Target contract | Test/gate | Wave | Terminal verdict | Commit |
|----|----------------------|-----------------|-----------|------|------------------|--------|
| H07 | `SessionVectorSearchAvailability` returns `embeddingModelMismatch`; service/MCP probe `embedding_meta` before embed | Same-dim different-model fails closed; no cosine ranking | `SemanticSearchIntegrityTests.testSemanticSearchRejectsSameDimensionDifferentModelWithoutEmbedding`; `EngramMCPExecutableTests.testSearchSemanticModelMismatchReturnsStructuredCodeWithoutEmbedding` | 8A | **CONFIRMED-FIXED** | `bdc95157` / `90b70690` |
| H12 | `CommandPaletteExportState` idle→inFlight→succeeded\|failed; results stay visible | Explicit export state machine; progress + Finder reveal; no list replace | `CommandPaletteTests.testExportStateInFlightShowsProgressAndBlocksDuplicateExport` (+ idle/succeeded/failed/clear/wire tests) | 8C | **CONFIRMED-FIXED** | `262d59a2` / `cfed29b5` |
| M02 | Failed scan phase records failure telemetry only; outer orchestration omits success sample | No success scan sample on required-phase failure | `ServiceTelemetryTests.testFailedScanPhaseDoesNotRecordSuccessSample_repro`; `testRunInitialScanOuterOrchestrationPhaseFailureOmitsSuccessSample` | 8E | **CONFIRMED-FIXED** | `c87fab56` / `f1486c2f` |
| M06 | Distinct degrade reasons: provider unavailable, corpus missing, model mismatch, breaker open | Structured reasons; no coarse single warning | `SemanticSearchIntegrityTests` provider/corpus/breaker cases; `SessionSemanticSearchIntegrityTests.testSemanticDegradeReasonWarningsNameConcreteCause` | 8A | **CONFIRMED-FIXED** | `bdc95157` / `90b70690` |
| M07 | `get_memory` warnings name actual provider/mismatch failure | Warning text matches failure class | `EngramMCPExecutableTests.testGetMemoryWarningNamesProviderFailureNotGenericProviderMissing`; `testGetMemoryInsightModelMismatchDoesNotEmbedAndNamesReason` | 8A | **CONFIRMED-FIXED** | `bdc95157` / `90b70690` |
| M08 | MCP + service use `EmbeddingGuardrails.sharedBreaker` | No private MCP breaker bypass | `EngramMCPExecutableTests.testMCPDatabaseUsesSharedEmbeddingBreakerWithoutPrivateBypass`; `SemanticSearchIntegrityTests.testServiceDefaultProviderFactoryUsesSharedBreaker` | 8A | **CONFIRMED-FIXED** | `bdc95157` / `90b70690` |
| M09 | Full-corpus rowid-ordered GRDB batches + constant-memory top-K; recency not eligibility | Older exact match outside former recency cap wins | `SemanticSearchIntegrityTests.testFullCorpusSemanticTopKPrefersOldExactMatchOutsideFormerRecencyCap`; `EngramMCPExecutableTests.testSearchSemanticFullCorpusPrefersOldExactMatchOutsideFormerCap`; `SessionSemanticSearchIntegrityTests.testCandidateBatchSizeIsBoundedAndNotRecencyEligibilityCap` | 8A | **CONFIRMED-FIXED** | `bdc95157` / `90b70690` |
| M11 | Default roles documented as user/assistant only in schema + description | tools/list and runtime default agree | `EngramMCPExecutableTests.testGetSessionRolesSchemaDocumentsUserAssistantDefault_repro` | 8B | **CONFIRMED-FIXED** | `130ed361` / `19c3ece9` |
| M12 | Service/MCP preserve `transcriptTooLarge` structured code | Not collapsed to `invalidRequest` | `EngramMCPExecutableTests.testExportPreservesTranscriptTooLargeStructuredCode_repro` | 8B | **CONFIRMED-FIXED** | `130ed361` / `19c3ece9` |
| M13 | Shared `KeychainSecretStore`; plaintext→`@keychain` migration with verify-before-clear | Idempotent Keychain migration; failed write retains plaintext | `EmbeddingSettingsKeychainTests` migration suite (plaintext once, marker load, missing, failed/interrupted, verify-read-back, idempotent) | 8A | **CONFIRMED-FIXED** | `6fe46fd7` / `d90aad5f` |
| M14 | Diagnostic composer redacts `embeddingApiKey` + normalized aliases | No exact-key bypass | `DiagnosticBundleComposerTests.testComposeRedactsEmbeddingApiKeyAliasesWithoutExactKeyBypass` | 8A | **CONFIRMED-FIXED** | `6fe46fd7` / `d90aad5f` |
| M15 | Secure settings writer: temp+rename, final POSIX `0600` on create and update | Broader perms repaired on update | `SecureSettingsFileWriterTests.testCreateWritesSettingsWithMode0600`; `testUpdateRepairsBroaderPermissionsTo0600` | 8A | **CONFIRMED-FIXED** | `6fe46fd7` / `d90aad5f` |
| M16 | MCP `get_session` default redaction matches export; `include_raw` opt-in; `redacted` flag in payload | No unredacted default | `EngramMCPExecutableTests.testGetSessionRedactsSecretsByDefaultAndAllowsRawOptIn_repro` | 8B | **CONFIRMED-FIXED** | `130ed361` / `19c3ece9` |
| M19 | Session `isFavorite` + `favoriteToggleTarget`; browse/starred/child symmetric toggle labels | Add/Remove labels match state | `SessionModelTests.testFavoriteToggleTargetIsSymmetricNegation`; `testFavoriteMenuLabelReflectsAddVersusRemove`; `testBrowseStarredAndChildCardsWireIsFavoriteSourceTruth` | 8C | **CONFIRMED-FIXED** | `262d59a2` / `cfed29b5` |
| L01 | Stdout events via `JSONEncoder` structured encoding | Quotes/control chars escaped; no string interpolation JSON | `ServiceTelemetryTests.testStdoutEventEncodingEscapesQuotesAndControlCharacters`; `EngramServiceIPCTests.testRunnerStdoutEventsUseStructuredJSONEncoderNotInterpolation` | 8E | **CONFIRMED-FIXED** | `c87fab56` / `f1486c2f` |
| L02 | Malformed `serviceLogs` payload → structured `invalidRequest` | No silent default on decode failure | `ServiceLogIPCTests.testServiceLogsMalformedPayloadReturnsInvalidRequest_repro`; `testServiceLogsNonJSONPayloadReturnsInvalidRequest` | 8E | **CONFIRMED-FIXED** | `c87fab56` / `f1486c2f` |
| L06 | `project_review` description derives scanner root count (not hard-coded prose) | Single source of truth for root count | `EngramMCPExecutableTests.testProjectReviewDescriptionUsesScannerRootCount_repro` | 8B | **CONFIRMED-FIXED** | `130ed361` / `19c3ece9` |
| L07 | `get_memory` structured payload includes type filter semantics | Requested/returned type truth in payload + goldens | `EngramMCPExecutableTests.testGetMemoryTypeFilterReturnsOnlyRequestedType`; `testGetMemoryWithoutTypeStillReturnsAllTypes`; `testGetMemoryMatchesGolden` | 8B | **CONFIRMED-FIXED** | `130ed361` / `19c3ece9` |
| L09 | `scripts/invariant-gates.json` allowlist → fixed argv; runner rejects smuggling | Invalid fixture gate fails; markdown never becomes shell | `tests/scripts/invariants-ledger.test.ts`; `scripts/check-invariants-ledger.sh`; `scripts/test-support/always-fail-invariant-gate.sh` | 8E | **CONFIRMED-FIXED** | `c87fab56` / `f1486c2f` |

### Residual coverage check

```text
H07 H12 M02 M06 M07 M08 M09 M11 M12 M13 M14 M15 M16 M19 L01 L02 L06 L07 L09
```

All 19 present above with terminal verdicts. Zero residual-open.

## Full Wave 7 ledger tallies (after Wave 8)

| Verdict | Count |
|---------|------:|
| CONFIRMED-FIXED | 43 |
| OVERTURNED | 0 |
| ACCEPTED-DESIGN | 0 |
| **Total** | **43** |

Wave 7 originally closed 24 rows as `CONFIRMED-FIXED`. Wave 8 closed the
remaining 19. No row was overturned or accepted-as-design in this closeout.

## Follow-up reconciliation (non-ledger)

| Former open follow-up | Disposition |
|-----------------------|-------------|
| Session export in-flight feedback | **Closed** via H12 / Wave 8C |
| Long project migration cancel/reconnect | **Closed** via Wave 8D (`c983a759`) |
| Disk-audit `last_accessed_at` / `access_count` consumer | **Closed** via Wave 8E E2E `testGetMemoryRanksByServiceRecordedAccessCount_diskAuditConsumer` |
| Normalize local ignore rules | **Closed** — universal artifacts already in shared `.gitignore` (`node_modules/`, `dist/`, `.husky/_/`); host-local `.git/info/exclude` remains uncommitted by design |
| Perf-integration residuals | **Already zero active** (2026-07-08); section marked closed |
| Sources-sync-3 nav consolidation | **Moved / already on** roadmap Decision pending (12-row table) |
| `ai_audit_log` desensitization design | **Moved / already on** roadmap Decision pending (12-row table) |
| FTS full-rebuild progress UI | **Closed as not implementation-ready** — palette still excludes rebuild; product-gated UX, not an open engineering defect |

## Backlog truth verification (docs-only gates)

Commands for the independent Codex gate (run from repo root after this commit):

```bash
# remediation ledger must not retain residual-open status tokens
! rg -n 'PARTIAL-FIXED|UNADJUDICATED' docs/reviews/2026-07-10-wave7-remediation-closeout.md
! rg -n '^## Open' docs/followups.md
rg -n '^## Decision pending' docs/roadmap.md
python3 - <<'PY'
from pathlib import Path
import re
text = Path("docs/roadmap.md").read_text()
body = text.split("## Decision pending",1)[1].split("## ",1)[0]
rows = [l for l in body.splitlines() if l.startswith("| ") and not l.startswith("| Item") and not re.match(r"^\|\s*-+", l)]
assert len(rows) == 12, len(rows)
print("roadmap decisions:", len(rows))
PY
git diff --check
```

Mechanical counts expected:

```text
Wave 7 audit ledger: 43 terminal / 0 residual-open
Engineering TODO: 0
Engineering follow-ups: 0
Roadmap decisions: 12 visible, not misreported as implemented
```

## Explicit non-claims (Task 7 out of scope here)

This docs-only closeout does **not** assert:

- Full Swift matrix green on the closeout SHA
- Remote Tests + CodeQL green on the closeout SHA
- Release archive / `release-verify` / notarization
- Local install, launch, socket, MCP, or scheduling smoke

Implementation merges already recorded focused suite evidence under their own
SHAs. Final same-SHA release acceptance remains Task 7 / Codex.

## Residual risks for Codex

1. **Docs-only authority:** verdicts cite merged Wave 8 source + named tests;
   this worker did not re-execute the Swift matrix.
2. **Task 7 still open:** engineering-zero *backlog truth* ≠ full Definition of
   Engineering Zero item 6 (CI/release/runtime on one SHA).
3. **Roadmap 12 decisions** remain owner-parked; do not relabel them as
   engineering TODO or follow-ups.
4. **Host-local exclude** may still list private paths; that is intentional and
   not a repo defect.
