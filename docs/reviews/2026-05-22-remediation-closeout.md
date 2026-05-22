# Round-7 Remediation Closeout (2026-05-22)

Implements the fixes from `2026-05-22-FINAL-report.md`. Done via 4 parallel
worktree agents (file-disjoint ownership) + a sequential integration/SST pass,
all merged to `main` (fast-forward, commits `286093f9..63d2b800`).

## Validation (merged tree on `main`)
- `xcodebuild -scheme Engram -configuration Debug` (signing off): **BUILD SUCCEEDED**, 0 errors (1852 Swift files).
- Tests: **EngramCoreTests 275/275**, **EngramServiceCore 63/63**, **EngramMCPTests 46/46** — 384 passing, 0 failures. (App-hosted EngramTests/UITests not run here: local codesign is unavailable in this env; their compile is green.)

## Fixed and landed
| Area | Items | Commit |
|---|---|---|
| Composition root (P0) | V1 FTS content writer (`IndexJobRunner` drains fts jobs, builds content, INSERTs `sessions_fts`; embedding jobs → `not_applicable`); V2 `migrate()` + `runInitialScan` wired in `EngramServiceRunner` + fail-fast on missing schema (`StartupComposition`); V3 SwiftIndexer counts only written rows + `indexStatus` distinguishes missing-schema | b7c8ebbb |
| Security | SEC-C1 web UI opt-in (`webUIEnabled` default off) + per-launch bearer token + Host/Origin checks + redaction; SEC-C2 `project_move` src/dst confined to session roots at handler boundary; SEC-H1 `getpeereid` + capability token for destructive cmds (wires the dead `unauthorized`); SEC-H3 `containsSensitivePathComponent` `Library/Keychains` now matched; SEC-M1 socket `chmod 0600` | b7c8ebbb, c3e399a9 |
| IPC | H1 accept() errno discrimination (no fatal break on EINTR/ECONNABORTED/EMFILE); H2 snippet truncated to 600 + symmetric `writeFrame` cap; M1 two-stage decode preserves real request id on error | c3e399a9 |
| Write path | WP-H1 datetime window normalized; WP-H2 `db.changesCount` (no trigger inflation); WP-H3 cascade trigger resets tier for suggested children; WP-M1 reconcileInsights guarded against empty-insights wipe | b7c8ebbb |
| Read/adapters | RA-1 `CascadeDiscovery` drains stdout before `waitUntilExit` (pipe deadlock); RA-2 `Antigravity.inferredCWD` returns the real transcript path, no longer fabricates `/Users/<user>/-Code-/`; RA-3 `WatchPathRules.maxDrainBatchSize` reads its own key | e2ed2535 |
| Observability/UI | OBS-C1 5 views read `OSLogStore` (or honest "not available") instead of always-empty tables; OBS-O2 app routes `index_error`→`.degraded` (menu-bar warning); 12 views moved DB reads to `Task.detached`; real a11y labels/values on charts; error states (AlertBanner); removed dead JSON tab / summary / Embeddings controls; "WAL Mode" reads real pragma | 286093f9 |
| Tiering | SST-5 ported `PROBE_FIRST_LINES` + full 6-entry `NOISE_PATTERNS` to Swift `SessionTier` for TS parity; added `SessionTierTests` (none existed) | 63d2b800 |
| Release | REL-C1 removed ditto fallback that shipped un-notarizable apps (fail loud; `--local-only` flag); REL-C2 real bundle test replaces text-match; bundle-hygiene gate (`release-verify.sh`); Hardened Runtime + secure timestamp + `--deep` verify; single-sourced version + `CFBundleVersion` bump; `deploy-local.sh`; tag-gated CI lane; CLAUDE.md 3 falsehoods corrected | ae82d7ec, e2ed2535 |
| Merge integrity | dup `WebUIServerError` enum merged; `EngramServiceReadProvider`/`UnixSocketEngramServiceTransport` conflict resolutions (FdBox cancellation + capability token); `copy-{mcp,service}-helper.sh` guarded `EXPANDED_CODE_SIGN_IDENTITY` under `set -u` | e2ed2535 |

## Deliberately deferred (with rationale)
- **SST full single-source consolidation** (8-way injection classifier dedup; one `PolycliProbeDetector`; one `ParentScoring`; `normalize()` unifying header-count vs stream so a `messageCount == messages.count` parity assertion can be added). These are **refactors**, not behavioral bugs; doing them hastily across the runtime + adapters risks regressions and conflicts with the "minimum-diff" working agreement. SST-5 (tier-rule parity) and the most acute behavioral risk are addressed; the structural dedup is recommended as a dedicated PR. The probe over-broad-match (real-review-as-probe) and Codex 4-vs-10 injection-tag narrowness remain as-is pending that consolidation.
- **OBS-C2 service-side `.degraded` SLA** (status command tracking last-scan outcome with an age threshold): the app already surfaces indexing failure via the existing `ServiceIndexErrorEvent` stdout channel (OBS-O2, landed), so the user-visible gap is covered; the service-side SLA timer is an enhancement, deferred.
- **Gemini cross-validation omissions (P3, unverified)**: WAL `-shm` permissions under App Sandbox, App Nap/daemon suspension, JSONDecoder memory on large transcripts, UI refresh strategy. Not yet code-verified; recommend a targeted follow-up.
- **Semantic search / embeddings / manual link-unlink / Windsurf+Antigravity ingest**: advertised-but-inert features. Fixed by removing the false UI/claims (not implementing multi-week features). Implementing them is product scope, not a bug fix.

## Notes / residual risk
- App-hosted test targets (EngramTests app UI, EngramUITests) compile but were not executed (no local signing). The fix-app agent ran them green in its worktree pre-merge.
- The full `xcodebuild archive` + notarization path (REL-H) is verified at project-generation + `release-verify.sh`-against-existing-bundle level, not via a real Developer-ID export (no cert/secret locally).
