# Finding disposition inventory (closeout)

**Updated:** 2026-07-18 (R11 evidence columns + R4+ follow-up links)  
**Consolidated PR:** #196 (`fix/audit-2026-07-17-consolidated`)  
**R4+ follow-up PR:** see `docs/followups.md` § “Post-review R4+ / residuals”

| ID | Status | Batch | Evidence (test / PR / residual home) | Notes |
|----|--------|-------|--------------------------------------|-------|
| H1 | fixed | C | `DatabaseManagerTests` project GROUP BY; #196 | |
| H2 | fixed | C | MCP CJK/`keywordSearchLike` fixtures; #196 | |
| M1 | fixed | E | `ServiceWriterGate` + Round5/M1 tests; #196 | pending+active long writes |
| M2 | fixed | E | index scan success tests; #196 | |
| M3 | fixed | E | `testSessionEmbeddingIsolatesPerSessionFailure_repro` | session path |
| M3-insight | fixed | R4+ | `testInsightEmbeddingIsolatesPoisonAndTerminates_repro` | was review R4 |
| M4 | fixed | E | `testReclamationCursorAdvancesOnlyPastProcessedCandidates_repro` | count cap |
| M4-budget | fixed | R4+ | `testReclamationCursorDoesNotSkipBudgetBoundEligibles_repro` | was review R5 |
| M5 | fixed | D/H/R3 | KPI + `countSessionsSince`/`sourceStats`/MCP stats repros | |
| M6 | fixed | F | Codex parity golden updated for tool counts; #196 | |
| M7 | fixed | F | Codex TailIndexing adapter tests | |
| M8 | fixed | F | parent-detection tests | |
| M9 | fixed | D | `AuditMediumMCPReproTests` negative limit | |
| M10 | fixed | F | Timeline generation tests | |
| M11 | fixed | G | hygiene-only CI gate | |
| M12 | fixed | D/R2 | JsonlPatch boundary + false-match repros | |
| M13 | fixed | F | FsOps case-only rename tests | |
| M14 | fixed | H/R10 | `testHasObjectAfterPut_behavioral_repro` / hasManifest | was grep theater |
| M15 | accepted-residual | residual | `docs/followups.md` | Discovery list throughput latent |
| M16 | fixed | E | dim mismatch tests | |
| M17 | fixed | E | model change reconcile tests | |
| M18 | fixed | D | MCP list skip/child fixtures | |
| M19 | fixed | D | get_costs hidden fixtures | |
| M20 | fixed | D | `AISettingsURLValidation` helper tests | |
| M21 | accepted-residual | residual | `docs/followups.md` R9 | Debounce only; MainActor I/O residual |
| M22 | fixed | F | reclamation refresh tests | |
| M23 | fixed | D | Gemini sidecar validation tests | |
| M24 | fixed | D | get_costs localtime fixtures | |
| M25 | fixed | F | digest action_date tests | |
| L1–L5, L9–L18, L20, L22, L24–L34, L36 | accepted-residual | residual | `docs/reviews/2026-07-17-accepted-residuals.md` + followups | Low backlog |
| L6–L8 | fixed | G | source-grep + DB tests | |
| L19 | accepted-residual | residual | accepted-residuals | TS CLI only |
| L21 | accepted-residual | residual | TODO public release | Notarization manual |
| L23 | accepted-residual | residual | accepted-residuals | docs retention |
| L35 | accepted-residual | residual | accepted-residuals | SchemaTool unused |
| SEC-H1 | fixed | B | offload TLS default + bare label tests | |
| SEC-H2 | fixed | A | secrets scrub tests | |
| SEC-M1 | fixed | A | TerminalLauncher no /tmp log | |
| SEC-M2 | fixed | B | O_NOFOLLOW memory tests | |
| SEC-M3 | fixed | B | Keychain fail-closed tests | |
| SEC-M4 | accepted-residual | residual | accepted-residuals / SECURITY.md | ops TLS=false |
| SEC-M5 | accepted-residual | residual | accepted-residuals | same-user MCP design |
| SEC-L1–L3, L5 | fixed | A/G | token/peer/socket tests | |
| SEC-L4 | accepted-residual | residual | accepted-residuals | prompt injection design |
| SEC-I1 | accepted-residual | residual | accepted-residuals | capability model intentional |
| SEC-I2 | accepted-residual | residual | accepted-residuals | no cert pinning |

**Counts (approx):** fixed defect Highs + defect Mediums closed with behavioral evidence on #196 / R4+; residual design/ops/lows tracked in accepted-residuals + followups (not bare status-only rows).

## Related

- Full-project review R1–R11: `docs/reviews/2026-07-18-full-project-review.md`
- Accepted residuals writeup: `docs/reviews/2026-07-17-accepted-residuals.md`
- Active backlog home: `docs/followups.md`, `docs/TODO.md`
