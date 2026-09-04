# All Confirmed Remediation Ledger — 2026-09-02

## Frozen scope

- Base: `33b6f8c95faaa7b2df25afe3037dd613e2085bde`
- Review-date-qualified tracked IDs: 115
- Independent implementation clusters after explicit aliases and test-only near-duplicates: 109
- Included catalogs:
  - 2026-08-31 verified review: 44 IDs / 41 implementation clusters
  - 2026-09-01 residual verification: 55 IDs / 53 implementation clusters
  - Round-12 still-valid residuals: 14 IDs / 13 implementation clusters
  - 2026-09-02 watchdog additions: 2 IDs / 2 implementation clusters
- Excluded: every rejected, duplicate-only, and stale row named by the verification reports.

## Mandatory implementation protocol

1. Re-check each assigned row against current source.
2. Add a focused failing `_repro` test and capture RED.
3. Apply the minimum production change.
4. Capture targeted GREEN and the relevant scheme/package gate.
5. Do not touch deferred IDs, rejected claims, production, deployment, Docker, `CHANGELOG.md`, or `MEMO.md`.

## Catalog A — 2026-08-31 (44 IDs)

- App/service: `app-lifecycle-1`, `app-lifecycle-2`, `app-lifecycle-3`, `writer-gate-1`, `writer-gate-2`, `service-commands-1`, `service-commands-4`, `service-runner-4`, `concurrency-1`.
- MCP/search: `mcp-registry-1`, `mcp-database-2`, `mcp-database-4`, `embeddings-search-1`, `embeddings-search-2`, `embeddings-search-3`.
- Adapters/caps: `adapters-claude-codex-1`, `adapters-gemini-cursor-vscode-1`, `adapters-opencode-copilot-1`, `adapters-jsonl-rest-1`, `adapters-archived-cache-1`, `stream-caps-1`, `stream-caps-2`, `stream-caps-3`, `stream-caps-4`, `stream-caps-5`, `tests-parity-2`, `tests-parity-4`.
- Index/backfill/tier/move: `startup-backfills-1`, `startup-backfills-2`, `session-tier-1`, `session-tier-2`, `parent-detection-1`, `project-move-1`, `project-move-2`.
- Archive/remote: `archive-v2-1`, `archive-v2-2`, `archive-v2-3`, `remote-sync-1`, `remote-sync-2`.
- UI/CLI/release: `core-read-1`, `ui-sessions-1`, `ci-release-4`, `cli-resume-2`, `cli-resume-3`.

Known same-change clusters: `writer-gate-2` + `service-commands-1`; `stream-caps-2` + `tests-parity-2`; `stream-caps-4` + `tests-parity-4`.

## Catalog B — 2026-09-01 (55 IDs)

- Service/MCP: `writer-gate-4`, `writer-gate-5`, `service-read-1`, `service-read-2`, `service-read-3`, `service-read-4`, `embeddings-search-4`, `mcp-registry-2`, `mcp-registry-3`, `mcp-registry-5`, `mcp-database-1`, `mcp-database-3`, `mcp-database-5`.
- Adapters: `adapters-opencode-copilot-2`, `adapters-opencode-copilot-3`, `adapters-opencode-copilot-4`, `adapters-jsonl-rest-3`, `adapters-jsonl-rest-4`, `adapters-jsonl-rest-5`, `adapters-claude-codex-3`, `adapters-gemini-cursor-vscode-5`, `adapters-archived-cache-2`, `adapters-archived-cache-3`, `adapters-archived-cache-4`, `adapters-archived-cache-5`.
- Index/backfill/move: `indexing-core-3`, `indexing-core-4`, `startup-backfills-3`, `startup-backfills-4`, `parent-detection-4`, `parent-detection-5`, `project-move-3`, `project-move-5`.
- Archive/remote: `archive-v2-4`, `archive-v2-5`, `archive-v2-6`, `remote-sync-4`, `remote-sync-5`.
- UI: `core-read-2`, `core-read-5`, `ui-sessions-2`, `ui-sessions-3`, `ui-sessions-4`, `ui-sessions-5`, `ui-sessions-6`, `ui-transcript-2`, `ui-transcript-4`, `ui-transcript-5`, `ui-search-settings-1`, `ui-search-settings-2`, `ui-search-settings-4`, `ui-search-settings-5`.
- Release/CLI: `ci-release-1`, `ci-release-3`, `cli-resume-1`.

Known same-hole pairs: `service-read-1` + `embeddings-search-4`; `core-read-2` + `ui-search-settings-4`.

## Catalog C — still-valid Round-12 residuals (14 IDs)

- Runtime secrets/settings: `secrets-nofollow-1`, `secrets-nofollow-regress-1`, `secrets-nofollow-3`, `secrets-nofollow-regress-3`, `apikey-empty-2`, `invariant-6-prod-2`.
- Navigation/test/terminal: `session-detail-id-1`, `mcp-hermetic-1`, `live-export-terminal-1`, `live-export-terminal-2`.
- Misc/release/server: `workitem-localtime-1`, `xcodeproj-untracked-1`, `xcodeproj-untracked-2`, `r11-dropped-2`.

Alias: `secrets-nofollow-3` + `secrets-nofollow-regress-3` are one implementation cluster.

## Catalog D — 2026-09-02 watchdog additions (2 IDs)

- `hq-watchdog-lock-fd-1`
- `hq-watchdog-health-predicate-1`

## Active wave 1 ownership

- W1-A App/service transport and runtime secrets: accepted 13/13 after re-gate (`PASS` / `APPROVED`).
- W1-B MCP/search core: accepted 11/11 (`PASS` / `APPROVED`).
- W1-C Watchdog/release/terminal utilities: accepted 12/12 after re-gate (`PASS` / `APPROVED`).

## Remaining wave groups

- Service read/status/concurrency.
- Adapter families and stream caps.
- Indexing, startup backfills, tiering, parent detection, and project move.
- Archive V2, remote sync, and RemoteServer HTTP boundaries.
- Sessions/home/timeline/repos UI.
- Transcript/navigation UI.
- SourcePulse/settings/secrets UI.
- Final CI/release/CLI leftovers and documentation reconciliation.

## Active wave 2 ownership

- W2-A Cursor identity/stream/resume cluster: accepted 6/6 after re-gate (`PASS` / `APPROVED`).
- W2-B Claude/Gemini/VSCode/Codex/Antigravity cluster: accepted 8/8 IDs (7 clusters), `PASS` / `APPROVED`; after W3-A's final Claude classifier change, root independently revalidated the overlap-focused set 8/8 on the final source.
- W2-C OpenCode/Copilot/Kimi/Qwen/Qoder cluster: accepted 10/10, `PASS` / `APPROVED`; focused 13/13 and owned classes 76/76. Full Core's only failure was an out-of-scope Cursor locator JSON key-order flake that passed on immediate single-test rerun. `adapters-archived-cache-4` remains owned by W2-B.

## Active wave 3 ownership

- W3-A ServiceRead/SourcePulse cluster: accepted 9/9 after blocker remediation and root re-gate; final-source Service focused 19/19 and App Source tests 29/29 passed, after the author full ServiceCore gate passed 818/818 with one skip.

## Current count invariant

- Independently accepted: 115 IDs.
- Active implementation or gate-pending: 0 IDs.
- Not yet started: 0 IDs.
- Total: 115 + 0 = 115 tracked IDs.

## Active wave 4 ownership

- W4-PM ProjectMove cluster: accepted 4/4 after root re-gate (`PASS` / `APPROVED`); final ProjectMove suite passed 303/303, root final-source focused passed 8/8, and full Core's only remaining failures were the active W5-RS RED tests.
- W4-IX indexing transaction and embedding cluster: accepted 3/3 after root re-gate (`PASS` / `APPROVED`); final-source focused 4/4 and scoped diff-check passed. Related W4 classes passed except for one concurrent W4-BF migration expectation, and the all-Core integration gate is deferred until concurrent RED packages stabilize.
- W4-BF startup backfill and grouping cluster: accepted 7/7 after root re-gate (`PASS` / `APPROVED`); final-source StartupBackfill + cascade tests passed 110/110, Service parent/tier tests passed 5/5, and author full ServiceCore passed 820/820 with one skip. Full Core integration remains deferred only for active ProjectMove changes.

## Active wave 5 ownership

- W5-RS remote sync and RemoteServer boundary cluster: accepted 5/5 after independent re-gate (`SPEC PASS` / `QUALITY APPROVED`); root independent RemoteSync classes passed 71/71, RemoteServer full passed 161/161, and the Service cancellation blocker was closed with focused 3/3 plus the full `RemoteSyncCoordinatorTests` class (50 executed, 1 skipped, 0 failed).
- W5-AR Archive V2 capture, backlog, and reclamation cluster: accepted 6/6 after blocker remediation and root re-gate. The independent gate caught a shared-CAS deletion race in `archive-v2-6`; the final fix leaves published finals intact on catalog failure, the deterministic concurrent-reuse repro is green, and root independently passed `ExactSourceCapturerTests` 12/12 on fresh DerivedData. Owned Service/Core gates and the prior full Core gate were also green.
- W5-UI sessions/home/timeline/repos cluster: accepted 8/8 after independent final-source re-gate (`SPEC PASS` / `QUALITY APPROVED`): `core-read-1`, `core-read-5`, `ui-sessions-1`, `ui-sessions-2`, `ui-sessions-3`, `ui-sessions-4`, `ui-sessions-5`, `ui-sessions-6`. The Timeline blocker was closed with true RED (2 tests / 7 failed assertions), then author full App passed 1137/1137. Independent final-source gates passed App focused 11/11, Core focused 2/2, related App 293/293, related Core 16/16, plus a 2/2 Popover recheck after W9 source drift. Filter/first-load uses full spinner and clears the prior snapshot; actual same-filter tick/mutation reloads preserve until swap, including failures. One assertion message inaccurately names access as a reload mutation; production `recordAccess` correctly retains the existing fire-and-forget/no-reload contract and this is non-blocking test wording only.

## Active wave 6 ownership

- W6-SR service runner, OpenCode live-role filtering, and archived-default-off reconciliation: accepted 3/3 after blocker remediation and independent final-source re-gate (`SPEC PASS` / `QUALITY APPROVED`): `service-runner-4`, `session-tier-2`, `adapters-archived-cache-5`. A deterministic RED proved stale startup configuration could re-hide an explicitly enabled source. The final writer-gate closure rereads configuration before hiding, with no nested gate. Author full ServiceCore passed 833 (1 skipped); independent focused 5/5 and related 35/35 passed with stable before/after source hashes (`/tmp/engram-w6sr-independent-regate-focused.log`, `/tmp/engram-w6sr-independent-regate-related.log`).

## Active wave 7 ownership

- W7-ST Settings, SourcePulse fail-closed toggles, and runtime-secret persistence/path cluster: accepted 5/5 after independent final-source re-gate (`SPEC PASS` / `QUALITY APPROVED`): `core-read-2`, `ui-search-settings-4`, `ui-search-settings-1`, `apikey-empty-2`, `invariant-6-prod-2`. The author captured initial RED plus absent-parent runtime-refresh and three-product-entry routing REDs, then passed focused/related and full App 1137/1137. The independent reviewer passed focused 6/6 and related 256/256 on separate DerivedData, confirmed imported count remains untouched by `listVisibleSQL`, and verified the resolved socket reaches all three product Settings routes (`/tmp/engram-w7st-independent-focused.log`, `/tmp/engram-w7st-independent-related.log`).

## Active wave 8 ownership

- W8-TR transcript loading, find consistency, and VSCode empty/error-state cluster: accepted 3/3 after root correction review and independent re-gate (`SPEC PASS` / `QUALITY APPROVED`): `ui-transcript-2`, `ui-transcript-4`, `ui-transcript-5`. The author captured initial Core/App REDs; root then caught an early-window completeness regression and required an additional RED before correction. Final author full gates passed Core 1449 (1 skipped) and App 1137. Root independently reviewed the final source/diff, passed Core `AdapterWindowedReadTests` 30/30 and App transcript focused 54/54 on fresh DerivedData, and passed scoped `git diff --check` (`/tmp/engram-root-w8tr-core-focused.log`, `/tmp/engram-root-w8tr-app-focused.log`).

## Active wave 9 ownership

- W9 final parent-link/navigation cluster: accepted 2/2 after independent final-source Gate (`SPEC PASS` / `QUALITY APPROVED`): `parent-detection-5`, `session-detail-id-1`. Segment 1 captured picker and IPC REDs, then made the picker-specific top-level query strict and rejected suggested hosts without writing the child. Segment 2 captured three navigation REDs, then completed captured live tokens on nil and identity-cleared a palette request whose global gate was stolen. Author full App passed 1139/1139 and full ServiceCore passed 833 (1 skipped). Independent focused/related gates passed App 5/5 + 239/239 and Service 1/1 + 6/6, with final source mtimes stable (`/tmp/engram-w9-app-focused.log`, `/tmp/engram-w9-service-focused.log`, `/tmp/engram-w9-app-related.log`, `/tmp/engram-w9-service-related.log`).

## Integration-only residuals outside the frozen 115-ID count

- Cursor composite locator integration flake is closed as test-only hygiene. The unstable full base64/JSON text equality now requires one result and compares decoded `sessionId`, `storeDBPath`, and `transcriptPath`; production locator encoding and composite-mtime behavior are unchanged. The Cursor test passed focused, its 14-test class, and 20/20 iterations. The misleading `access` wording in the Timeline preserve-reload assertion message was also corrected without changing the assertion or production behavior (`/tmp/engram-integration-hygiene-cursor-20x.log`, `/tmp/engram-integration-hygiene-cursor-class.log`, `/tmp/engram-integration-hygiene-browse-class.log`).
- The final MCP full gate exposed one stale test-only root-count literal: production correctly advertised all 14 current roots while the test still required 13. A focused RED captured that mismatch; the test now derives the catalog count from an explicit temporary HOME, retains the numeric-format and historical-seven guards, and the final MCP gate passed 265/265 (`/tmp/engram-mcp-count-focused-red.log`, `/tmp/engram-mcp-count-focused-green.log`, `/tmp/engram-final-mcp-log.cgVHhG`).
- The first commit attempt exposed checkout-name-dependent XcodeGen output for the two external UI fixture resources, then the real commit-hook environment exposed unanchored Git queries after `cd macos`: an absolute linked-worktree `GIT_DIR` made every generated path appear untracked. Both resources now use the explicit `UITestFixtures` group, and the script queries root-relative paths through `git -C "$ROOT_DIR"`. Both regressions moved from RED to GREEN, pinned XcodeGen 2.45.4 produced byte-identical pbxproj output in two differently named checkouts, and ordinary plus explicit-`GIT_DIR` pre-commit runs passed (`/tmp/engram-20260904-xcodegen-worktree-focused.log`, `/tmp/engram-20260904-xcodegen-worktree-drift.log`).

## Final integration gates

- Catalog parser: A 44 + B 55 + C 14 + D 2 = 115 unique confirmed IDs; package gates sum to 115/115 accepted.
- Node: build, lint, knip, test typecheck, and coverage exited zero; coverage passed 130 files / 1,561 tests. Lint retained one warning and one schema-version info.
- Swift final-source results: the 2026-09-04 Engram rerun passed 2,588 total (2,587 passed, one skipped; Core 1,449 + App 1,139). The 2026-09-02 independent gates passed Core 1,449 (one skipped), MCP 265, Service 833 (one skipped), and Remote 161; the RemoteServer executable also linked successfully in a fresh Debug build.
- A 2026-09-04 pre-commit Engram rerun exposed the existing writer-busy repro as a real stderr/termination ordering race. The minimal no-sleep fix serializes both stderr read paths, drains to EOF after child termination, and classifies only after the drain. The focused test, 20 consecutive executions, the 54-test launcher class, and the complete 2,588-test Engram gate then passed.
- The worktree-stable XcodeGen resource-group and commit-hook Git-context regressions passed 8 tests with two skipped; test typecheck, Biome, two-directory byte comparison, the real project drift gate, and ordinary plus explicit-`GIT_DIR` pre-commit runs also passed.
- Adapter parity, fixture schema, temporary-output fixture regeneration with byte-for-byte DB comparison, MCP stats-golden consistency, negative-contract audit, generated-path audit, and `git diff --check` passed.
- Focused current-source XCUITest capture did not initialize: the 2026-09-04 fresh runner hung before establishing its XCTest connection, with diagnostics stopped in `AppleSystemPolicy` evaluation before normal test startup. No test body or screenshot ran. The old 2026-08-22 screenshot compare is non-current evidence. UI visuals, deployed-server integration, signed release packaging, remote CI, deployment, and machine runtime remain explicitly unverified at this pre-deployment checkpoint.
- This ledger records remediation and pre-deployment validation. Integration and deployment require separate dated evidence. No xcodegen, Docker, tag, public release, notarization, or production-data mutation is part of this pass.
