# Wave 7 Remediation Closeout — 2026-07-10

**Program:** 43-item remediation (42 audit findings + `S01` scan scheduling)  
**Design:** `docs/superpowers/specs/2026-07-10-wave7-43-item-remediation-design.md`  
**Plan:** `docs/superpowers/plans/2026-07-10-wave7-43-item-remediation.md`  
**Baseline HEAD:** `8bdb6d54` (design commit on `main`; audit input `a011e2fb`)  
**Input audit:** `docs/reviews/2026-07-10-multi-expert-audit.md` (untracked evidence; not staged)

## Constraints (from design)

- Swift product behavior is authoritative; no Node product entrypoints.
- App/MCP writes go through `EngramServiceClient` / `ServiceWriterGate`.
- Do not edit `macos/Engram.xcodeproj` directly; regenerate via XcodeGen when needed.
- `subagent` and `dispatched` remain `tier = 'skip'` across ambiguous/unlink/cascade.
- TDD per behavior change; no install/launch until Task 8.
- Verdicts: `CONFIRMED-FIXED` | `PARTIAL-FIXED` | `OVERTURNED` only (no `UNADJUDICATED` at close).

## Ledger

| ID | Verdict | Fix commit | Tests | Evidence | Residual risk |
|----|---------|------------|-------|----------|---------------|
| C01 | UNADJUDICATED | — | — | — | — |
| H01 | UNADJUDICATED | — | — | — | — |
| H02 | UNADJUDICATED | — | — | — | — |
| H03 | UNADJUDICATED | — | — | — | — |
| H04 | UNADJUDICATED | — | — | — | — |
| H05 | UNADJUDICATED | — | — | — | — |
| H06 | UNADJUDICATED | — | — | — | — |
| H07 | UNADJUDICATED | — | — | — | — |
| H08 | UNADJUDICATED | — | — | — | — |
| H09 | UNADJUDICATED | — | — | — | — |
| H10 | UNADJUDICATED | — | — | — | — |
| H11 | UNADJUDICATED | — | — | — | — |
| H12 | UNADJUDICATED | — | — | — | — |
| M01 | UNADJUDICATED | — | — | — | — |
| M02 | UNADJUDICATED | — | — | — | — |
| M03 | UNADJUDICATED | — | — | — | — |
| M04 | UNADJUDICATED | — | — | — | — |
| M05 | UNADJUDICATED | — | — | — | — |
| M06 | UNADJUDICATED | — | — | — | — |
| M07 | UNADJUDICATED | — | — | — | — |
| M08 | UNADJUDICATED | — | — | — | — |
| M09 | UNADJUDICATED | — | — | — | — |
| M10 | UNADJUDICATED | — | — | — | — |
| M11 | UNADJUDICATED | — | — | — | — |
| M12 | UNADJUDICATED | — | — | — | — |
| M13 | UNADJUDICATED | — | — | — | — |
| M14 | UNADJUDICATED | — | — | — | — |
| M15 | UNADJUDICATED | — | — | — | — |
| M16 | UNADJUDICATED | — | — | — | — |
| M17 | UNADJUDICATED | — | — | — | — |
| M18 | UNADJUDICATED | — | — | — | — |
| M19 | UNADJUDICATED | — | — | — | — |
| M20 | UNADJUDICATED | — | — | — | — |
| L01 | UNADJUDICATED | — | — | — | — |
| L02 | UNADJUDICATED | — | — | — | — |
| L03 | UNADJUDICATED | — | — | — | — |
| L04 | UNADJUDICATED | — | — | — | — |
| L05 | UNADJUDICATED | — | — | — | — |
| L06 | UNADJUDICATED | — | — | — | — |
| L07 | UNADJUDICATED | — | — | — | — |
| L08 | UNADJUDICATED | — | — | — | — |
| L09 | UNADJUDICATED | — | — | — | — |
| S01 | UNADJUDICATED | — | — | — | — |

## Tallies (update at close)

| Verdict | Count |
|---------|-------|
| CONFIRMED-FIXED | 0 |
| PARTIAL-FIXED | 0 |
| OVERTURNED | 0 |
| UNADJUDICATED | 43 |

## Final release checklist

- [ ] Full Swift matrix green (`Engram` −UITests, `EngramCoreTests`, `EngramMCPTests`, `EngramServiceCore`)
- [ ] Local release build + verifier (no node/dist/web pollution)
- [ ] Install + launch + live socket + MCP initialize/tools.list (or honest env failure capture)
- [ ] Orca handoff to Codex with ledger tallies + residual risks

## Wave commits

| Wave | Commit | Notes |
|------|--------|-------|
| Task 1 ledger open | *(pending)* | all rows UNADJUDICATED |
| 7A Index/FTS | — | — |
| 7B Parent/tier | — | — |
| 7C Service/scheduling | — | — |
| 7D Semantic/MCP/security | — | — |
| 7E SwiftUI | — | — |
| 7F Docs/gates | — | — |
| Task 8 verify | — | — |
