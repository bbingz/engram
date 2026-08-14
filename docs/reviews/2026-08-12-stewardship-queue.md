# Engram stewardship priority queue — 2026-08-12

Owner: Grok (lead) + Herdr Codex `retro-handler` (w5:p1)  
Sources: two-round-retro-2 confirmed findings, `docs/TODO.md`, `docs/followups.md`, `docs/roadmap.md`  
Scope rule: Swift product path only; writes via service/writer gate; no Node product startup.

## Active

| Rank | ID | Sev | Title | Owner path | Done-when | Status |
|------|----|-----|-------|------------|-----------|--------|
| 1 | RETRO-P1-POPOVER | P1 | Popover omits top-level parent filter → child rows as top | implementer | `PopoverView` uses `SessionVisibilityFilter.topLevelSQL` (or equivalent parent+suggested NULL); `_repro`/UI-path unit test green | **DONE** 2026-08-12 |
| 2 | RETRO-P1-PARENT-VALIDATE | P1 | Path parent write lacks existence/depth/skip checks; startup never reconciles dangling | Codex | Writer validates parent; startup backfill/reconcile clears illegal parents; regression tests | **DONE** 2026-08-12 (Codex residual) |
| 3 | RETRO-P1-AGENTID-COLLISION | P1 | Empty agentId subagent id falls back to parent sessionId → row clobber | implementer | Subagent without agentId gets stable non-parent id or is skipped; conflict `_repro` green | **DONE** 2026-08-12 |
| 4 | RETRO-P1-SOURCE-DISABLE-BYPASS | P1 | disabledSources filters adapter.source only; Claude reclass still indexes as other sources | Codex | Post-detect / post-parse filter honors disabled set; disabled derived Archive locators park without a fake success state and requeue on enable | **DONE** 2026-08-12 (Codex residual + Archive churn closeout) |
| 5 | RETRO-P1-SOURCE-ENABLE-UNHIDE | P1 | `setSourceEnabled(true)` mass-clears `hidden_at` for whole source | implementer | Enable only unhides source-disable hides (or restores local_state); user manual hide preserved | **DONE** 2026-08-12 |
| 6 | RETRO-P1-SETTINGS-DB-SPLIT | P1 | Settings.json then SQLite; no shared rollback | Codex | Order/compensation so settings+DB converge or fail closed | **DONE** 2026-08-12 (Codex residual) |
| 7 | RETRO-P1-PROJECT-MOVE-SPLIT | P1 | Project-move `markFsDone` / DB apply two writer transactions | Codex | Single transaction or durable recover for `fs_done` mid-failure | **DONE** 2026-08-12 (provable Phase-B startup recovery) |
| 8 | RETRO-P1-GET-MEMORY-EMPTY | P1 | get_memory empty path suppresses degrade warning | implementer | Empty memory result still surfaces degrade warning when applicable; MCP executable `_repro` | **DONE** 2026-08-12 (MCP RPC `_repro`) |
| 9 | RETRO-P1-INVARIANT2-TEST | P1 | Invariant 2 lacks IPC setParent tier `_repro` | Codex | Swift IPC test: link does not upgrade skip child | **DONE** 2026-08-12 (Codex residual) |

## Deferred this cycle (queued, not active)

| Rank | ID | Sev | Title | Why deferred | Done-when |
|------|----|-----|-------|--------------|-----------|
| 10 | RETRO-P2-SKIP-PARENT | P2 | Generic/IPC can link to skip parent | **DONE** 2026-08-12 | Reject skip parent on IPC link — landed |
| 11 | RETRO-P2-TODAY-PARENTS | P2 | todayParents emitted before backfills | **DONE** 2026-08-12 | Zero before first successful scan; `_repro` green |
| 12 | RETRO-P2-INVARIANT-LEDGER | P2 | Dual-era not in invariants ledger | **DONE** 2026-08-12 | `docs/invariants.md` §15 |
| 13 | RETRO-P2-DENYLIST-CASE | P2 | Case-sensitive denylist | **DONE** 2026-08-12 | Folded compare — landed |
| 14 | RETRO-P2-TEST-MUTATOR | P2 | Prod `test.write_intent` surface | **DONE** 2026-08-12 | Hidden outside Debug builds |
| 15 | RETRO-NIT-TOKEN-TIMING | nit | Non-constant-time token compare | **DONE** 2026-08-12 | Constant-time compare |
| 20 | TODO-REL-1.0.5 | release | Notarize/publish `v1.0.5` | **BLOCKED** — TODO forbids signing/Keychain/tag without explicit human auth | Human auth + notarization pass |
| 21 | FOLLOW-ALIAS-P2 | low | Same-basename ghost alias remove | No repro host | Only if repro appears |
| 22 | ROADMAP-DECISION | product | 12 Decision-pending rows | Parked until release baseline | Product owner pick |

## False-positive / partial notes (this cull)

| Claim | Verdict | Evidence |
|-------|---------|----------|
| Popover parent filter drift | **CONFIRMED** | `PopoverView.swift:265-268` only hidden+skip+HumanDriven; no parent/suggested NULL |
| Path parent unvalidated | **CONFIRMED** | Sticky CASE write; no existence check at 374-382 |
| Empty agentId collision | **CONFIRMED** | `id()` returns `sessionId` for subagents when agentId empty |
| Source disable bypass | **CONFIRMED** | Filter on `$0.source.rawValue` only |
| Enable mass unhide | **CONFIRMED** | `UPDATE … hidden_at=NULL WHERE source=?` |
| Project-move two-phase | **CONFIRMED / DONE** | Recover was read-only and startup only failed stale rows; startup now resumes old-absent/new-present `fs_done` and preserves compensated rows |
| Release 1.0.5 deploy | **BLOCKED** | `docs/TODO.md` authorization boundary |

## Brainstorm (if health P1s clear)

1. Cursor CWD ownership contract (`CURSOR-CWD-001` followups) — design then implement.  
2. MCP object-root residual after #215 — re-verification **PASS** at rank 32.
3. Competitive gap: session “resume in original tool” deep-link UX (roadmap-adjacent).  
4. Archive V2 bounded discovery exporters (followups deferred engineering).

## Cycle contract

- Ship one PR for the largest coherent Codex batch of CONFIRMED P1s that tests pass.  
- Do **not** push `v*` or notarize without TODO authorization.  
- Daily retro: `docs/reviews/2026-08-12-daily-retro.md`.

## Next cycle (enqueued after P1 clear)

| Rank | ID | Sev | Title | Owner path | Done-when | Status |
|------|----|-----|-------|------------|-----------|--------|
| 30 | CURSOR-CWD-001 | P2 | Cursor workspace ownership must not use unrelated file selection as authoritative CWD | implementer | Accepted design + unique pointer-index ownership + named regression tests for wrong selection/ambiguity | **DONE** 2026-08-12 |
| 31 | ARCH-001 | debt | Triple Read SQL stacks / shared CoreRead predicates | implementer | Shared predicate module + cross-surface parity suite | **PARTIAL — A/B/C/D DONE**: ARCH-001A–C shipped; ARCH-001D keyword id parity is #351 at `main@841ad4a8`. Full CoreRead pool/DTO migration remains deferred; ARCH-001 stays open. |
| 32 | MCP-001-REVERIFY | P2 | Post-#215 MCP object-root contract residual audit | verifier | Re-grep every shipped MCP success-result constructor; either prove object-root coverage or capture an actionable residual with a named unit regression before changing production code | **DONE / PASS** 2026-08-12 — #215's object-root fix remains present; shipped Swift routes, executable contracts, and golden fixtures expose no actionable residual. |
| 33 | ARCHIVE-DISCOVERY-001 | debt | Restart-stable bounded steady-state exact-source locator discovery | design-first implementer | After an explicit O(N) bootstrap, a durable locator inventory + FSEvents cursor makes normal discovery/capture bounded across restart; event-loss and capture-before-parse regressions pass | **DESIGN-READY / IMPLEMENTATION DEFERRED** — residual confirmed on `main@5114507f`; no safe prefix/limit patch. Scope and Done-when: `docs/reviews/2026-08-12-archive-discovery-001-design-scope.md`. |
| 34 | REMOTE-MANIFEST-SCHEMA-001 | P2 | Remote Sync manifests accept unsupported schema versions | implementer | `ManifestCodec.decode` rejects unsupported manifest versions, aggregate catalog version is validated, valid peers still survive a malformed peer; named unit regressions cover direct decode and catalog paths | **DONE** 2026-08-12 — PR #317 merged at `main@ecd13db0`. |
| 35 | REMOTE-TELEMETRY-001 | P2 | Archive storage failures are mislabeled as internal telemetry errors | implementer | Archive 503 and 507 responses map to `storage_unavailable`, unrelated 5xx remain `internal_error`, and a named unit regression plus the telemetry-store test class pass | **DONE** 2026-08-12 — PR #318 merged at `main@2ddaa7a2`. |
| 36 | HOME-BADGE-001 | low | Home Changed Repos badge advertises full count while rendering prefix(5) | implementer | Badge clamps with todayPanelRowLimit; See-all/prefix use same limit; named _repro | **DONE** 2026-08-12 — PR #319 merged at `main@7c158cdc`. |
| 37 | LOGSTREAM-MODULES-001 | low | LogStream module picker frozen after first load | implementer | Merge observed modules every reload; late modules stay listed; named _repro | **DONE** 2026-08-12 — PR #320 merged at `main@ba7ffc8f`. |
| 38 | MCP-HYBRID-ZIP-001 | low | MCP hybrid fusion zip mislabels when session drops mid-search | implementer | Index semantic results by session.id; named _repro | **DONE** 2026-08-12 — PR #321 merged at `main@4e243afd`. |
| 39 | REMOTE-STATUS-PERSIST-001 | low | /v2/archive/status force-persists telemetry every poll | implementer | status uses forcePersist:false; consecutive polls within flush window do not rewrite status-v1.json; named _repro | **DONE** 2026-08-12 — PR #322 merged at `main@dcb2b3d9`. |
| 40 | SERVICE-CHECKPOINT-SHUTDOWN-001 | low | Graceful shutdown does not quiesce the periodic WAL checkpoint and final TRUNCATE inherits cancellation | implementer | Cancel and await periodic checkpoint before startup/final TRUNCATE; final checkpoint runs in a fresh cancellation context; named regressions pass | **DONE** 2026-08-12 — PR #323 merged at `main@dc5a5128`. |
| 41 | REMOTE-CATALOG-MEM-001 | low | Legacy /v1/catalog aggregates all peer manifests in memory without a request bound | implementer | Stop discovery after 1,024 matching peers; cap cumulative decoded manifest bytes and the serialized response at 4 MiB; return 413 on either limit; named live regressions pass | **DONE** 2026-08-12 — PR #325 merged at `main@c9c6c7f9`; audit L29. |
| 43 | INDEXER-BACKPRESSURE-001 | low | SwiftIndexer producer can outrun its 100-row consumer batch through an unbounded AsyncThrowingStream | implementer | Await each full 100-row write before scanning more snapshots; preserve collection; named producer-backpressure and write-failure regressions pass | **DONE** 2026-08-12 — PR #330 merged at `main@53bd4cc4`; audit L17. |
| 44 | SUGGESTED-PARENT-RESCORE-001 | low | Detection-version bumps leave stale single suggested-parent rows unscored | implementer | Invalidate non-manual/non-confirmed single suggestions, rescore in the same startup pass, and preserve confirmed/manual links plus skip classification | **DONE** 2026-08-13 — PR #331 merged at `main@5ed938e4`; audit L11. |
| 45 | GEMINI-JSON-FSYNC-001 | low | Gemini projects.json writeAtomic skips temp-file and parent-dir fsync (L26) | implementer | Fsync temp before rename and parent dir after, matching JsonlPatch; `testAtomicWriterFsyncsTempAndParentDirectory_repro` | **DONE** 2026-08-13 — PR #332 merged at `main@b344fa56`; audit L26. |
| 46 | RECLAMATION-ABORT-001 | low | One recover, eligible-plan, or CAS-evict failure aborts the entire reclamation cycle | implementer | Contain item failures while continuing later recovery, reclaim, and CAS work; rethrow cancellation; never advance the cursor beyond a failed eligible row; named coordinator regressions pass | **DONE** 2026-08-13 — PR #333 merged at `main@069d19e0`; audit L5. |
| 48 | BROWSE-SORT-INDEX-001 | low | Default updated-desc browse filesorts the list-visible session set (L9) | implementer | Fresh migration creates an activity-time expression index; representative list-visible `EXPLAIN QUERY PLAN` uses it without a temporary B-tree; named `_repro` passes | **DONE** 2026-08-13 — PR #335 merged at `main@88a1a2e0`; audit L9. |
| 47 | SESSION-DETAIL-FILTER-001 | low | SessionDetailView full type-visibility filtering scans 100k+ loaded rows synchronously on the main actor | implementer | Full-prefix visibility loop runs in cancellable detached work; named `_repro` | **DONE** 2026-08-13 — PR #334 merged at `main@54d0fce4`; audit L32. |
| 49 | SCHEMA-TOOL-DEAD-001 | low | EngramCoreSchemaTool is a build target with no caller, test, or bundle wiring (L35) | implementer | Remove its sources, XcodeGen target/scheme/dependencies, and generated project artifacts; named source-of-truth regression passes | **DONE** 2026-08-13 — PR #336 merged at `main@c39c0ac0`; audit L35. |
| 50 | FTS-H01-TS-001 | low | Retained TypeScript FTS rebuild version 3 can swap away eligible live rows for terminal or never-replayed jobs (L20) | implementer | Copy missing eligible live rows into the rebuild table, refuse an incomplete swap, keep `FTS_VERSION='3'` | **DONE** 2026-08-13 — PR #337 merged at `main@dffb882f`; audit L20. |
| 51 | PERF-YML-DOCS-001 | low | Nightly/on-demand perf workflow is intentionally non-gating but that policy is undocumented on the workflow (L22) | implementer | Add an explicit header policy without changing triggers/jobs; named source-contract `_repro` | **DONE** 2026-08-13 — PR #338 merged at `main@2d9644aa`; audit L22. |
| 52 | DOCS-INDEX-RETENTION-001 | low | `docs/archive` and `docs/reviews` lack scoped indexes and an explicit retention policy (L23) | implementer | Both directories document navigation, current-authority boundaries, and no age-only deletion; `indexes archive and review evidence with explicit retention rules_repro` pins the policy | **DONE** 2026-08-13 — PR #339 merged at `main@2aa7f84b`; audit L23. |
| 53 | MCP-STDIO-DEAD-001 | low | `MCPStdioServer.handle()` retains an unreachable second `tools/call` dispatch (L13) | implementer | Keep the cancellable read-loop fast path as the sole dispatch; remove the dead switch case; named source-contract and live stdio regressions pass | **DONE** 2026-08-13 — PR #340 merged at `main@b3165b8b`. |
| 54 | ADAPTER-STREAM-INJECTION-001 | low | CommandCode, Qwen, Qoder, and Iflow stream paths emit injected wrappers as user despite batch classification (L10) | implementer | Reuse each adapter's existing injection predicate for streamed roles; real user counts and first-user summary stay aligned; four named `_repro`s pass | **DONE** 2026-08-13 — PR #341 merged at `main@2d6f3f27`. |
| 55 | GEMINI-TOOL-EVENTS-001 | low | Gemini CLI session metadata hardcodes zero tool messages and its stream path drops persisted tool events (L-b) | implementer | Count and stream real `toolCalls[]`/`functionCall` events through one normalizer while preserving non-tool roles and excluding ordinary info; named `_repro`s pass | **DONE** 2026-08-13 — PR #342 merged at `main@2c405175`. |
| 56 | WARP-TAB-0600-001 | low | Warp tab config written without forced 0600 (L-e / SEC-006) | implementer | Atomic write then POSIX 0600; overwrite of a 0644 file repairs mode; launch path uses the helper | **DONE** 2026-08-13 — PR #343 merged at `main@4804ac03`. |
| 57 | ARCHIVE-SYNC-REFRESH-001 | low | Archive Sync status refresh failures are silently swallowed (L-d remainder) | implementer | A current-generation failure clears stale status and sets the localized user-visible error; suppressed action refreshes preserve their result; no polling is added; named `_repro` passes | **DONE** 2026-08-13 — PR #344 merged at `main@6cff11ef`; the no-poll half remains an intentional product choice. |
| 58 | GET-CONTEXT-COST-TODAY-001 | low | `get_context` "Cost today" uses a UTC day window while `get_costs` groups by local day (L-g) | implementer | Honor process-local / `TZ` calendar day via `contextTimeZone()`; Shanghai includes previous-UTC-evening spend; UTC still isolates the UTC day; named `_repro` passes | **DONE** 2026-08-13 — PR #345 merged at `main@85d8d3c9`. |
| 59 | TIMELINE-CONTENT-REFRESH-001 | low | Timeline (and other browse pages) only reload when `totalSessions` changes, not when a scan updates existing session content (L-c) | implementer | Status publishes `lastScanAt`; store `browseReloadToken` changes on content-only scans; Timeline/Home/Sessions/Activity/Projects/Agents key `.task(id:)` on it; named `_repro`s pass | **DONE** 2026-08-13 — PR #346 merged at `main@11c568f3`. |
| 60 | DERIVEDDATA-RELEASE-PLAINTEXT-001 | low | DerivedData Release may bypass Keychain and persist API keys in plaintext settings (L-f) | implementer | Keep DEBUG/DerivedData Keychain bypass; allow plaintext fallback only under `#if DEBUG`; Release stays fail-closed; named source-contract `_repro` passes | **DONE** 2026-08-13 — PR #347 merged at `main@8a1a1451`; audit L-f. |
| 61 | MCP-SEARCH-MIN-LENGTH-001 | low | MCP search accepts 1-char LIKE hits the app/service reject (L-a) | implementer | Guard `normalizedQuery.count < 2` like `Database.swift:568` / `EngramServiceReadProvider.swift:530`; keep 2-char Latin on LIKE; named `_repro` | **DONE** 2026-08-13 — PR #348 merged at `main@444c5d6c`; audit L-a. |
| 62 | ARCH-001D-PARITY | debt | ARCH-001 leftover: no executable cross-surface keyword-search parity contract | implementer | One fixture DB and the same trimmed non-CJK Latin keyword query make app `Database.search` / service `EngramServiceReadProvider.search` / MCP `searchSessions` return the same session ids; start at `macos/Engram/Core/Database.swift:561` vs `macos/EngramService/Core/EngramServiceReadProvider.swift:527` vs `macos/EngramMCP/Core/MCPDatabase.swift:1018` | **DONE** 2026-08-13 — PR #351 merged at `main@841ad4a8`. |
| 63 | TS-SAFEMOVEDIR-CASE-001 | low | TS `safeMoveDir` lacks the Swift M13 case-only rename exception (L-j) | implementer | Same-realpath destinations are not treated as collisions; named Vitest repro passes; product moves stay Swift | **DONE** 2026-08-13 — PR #353 merged at `main@b74836bd`. |
| 64 | REPO-DISCOVERY-COOLDOWN-001 | low | Repo discovery writes the 6h cooldown at selection, so a failed git probe burns the success window (F3) | implementer | `selectCandidates` is read-only; `recordOutcomes` applies 6h only after a successful probe and 15m after a nil probe; named `_repro`s pass | **DONE** 2026-08-13 — PR #355 merged at `main@9090e16d`. |
| 65 | SETTINGS-MAINACTOR-IO-001 | low | AI settings debounce still performs flock/Keychain I/O on MainActor after the timer (R9 residual) | implementer | Snapshot on MainActor, persist Keychain + settings.json off-main; leave-flush still lands; named `_repro` | **DONE** 2026-08-13 — PR #356 merged at `main@434892f0`. |
| 66 | ADAPTER-EMPTY-SESSION-001 | low | Only Claude / Qwen / VS Code return `.noVisibleMessages` for empty or metadata-only files (R184-3) | implementer | Codex `parseSessionInfo` fails closed on zero visible counts after a valid `session_meta`; named `_repro`. Remaining adapters stay later slices. | **DONE** 2026-08-13 — PR #357 Codex slice at `main@c8c42b64`. |
| 67 | ADAPTER-EMPTY-SESSION-001B | low | CommandCode / Iflow still index injection-only files as zero-count sessions (R184-3 remainder) | implementer | Both adapters fail closed on zero visible user/assistant/tool counts; named `_repro`s. Other adapters stay later slices. | **DONE** 2026-08-13 — PR #358 at `main@237aa757`. |
| 68 | ADAPTER-EMPTY-SESSION-001C | low | Gemini empty/content-less files and Qoder injection-only files still index as zero-count sessions (R184-3 remainder) | implementer | Gemini `parseSessionInfo` and Qoder fail closed on zero visible user/assistant/tool counts; named `_repro`s. Cursor and remaining adapters stay later slices. | **DONE** 2026-08-13 — PR #359 at `main@43ca14bc`. |
| 69 | ADAPTER-EMPTY-SESSION-001D | low | Cursor composers with no visible bubbles still index as zero-count sessions (R184-3 remainder) | implementer | `parseSessionInfo` fails closed on zero visible user/assistant counts; named `_repro`. Remaining adapters stay later slices. | **DONE** 2026-08-13 — PR #360 at `main@871e2a12`. |
| 70 | ADAPTER-EMPTY-SESSION-001E | low | Kimi wire/context metadata with no conversation turns still indexes as a zero-count session (R184-3 remainder) | implementer | `parseSessionInfo` fails closed on zero visible user/assistant/tool counts; named `_repro`. Remaining adapters stay later slices. | **DONE** 2026-08-13 — PR #361 at `main@a6a2348b`. |
| 71 | ADAPTER-EMPTY-SESSION-001F | low | Timestamped Cline metadata-only files still index as zero-count sessions (R184-3 remainder) | implementer | `parseSessionInfo` fails closed on zero visible user/assistant counts; named `_repro`. Remaining adapters stay later slices. | **DONE** 2026-08-13 — PR #362 at `main@7d40c1ad`. |
| 72 | ADAPTER-EMPTY-SESSION-001G | low | OpenCode live sessions with no contentful text still index as zero-count sessions (R184-3 remainder) | implementer | `parseSessionInfo` fails closed on zero visible user/assistant counts; named `_repro`. Remaining adapters stay later slices. | **DONE** 2026-08-13 — PR #363 at `main@fc5c70d4`. |
| 73 | ADAPTER-EMPTY-SESSION-001H | low | Windsurf metadata-only Cascade cache files still index as zero-count sessions (R184-3 remainder) | implementer | `parseSessionInfo` fails closed on zero visible user/assistant counts; named `_repro`. Remaining adapters stay later slices. | **DONE** 2026-08-13 — PR #364 at `main@1e3c610e`. |
| 74 | ADAPTER-EMPTY-SESSION-001I | low | Antigravity Cascade cache and CLI paths misclassify valid-id sessions with no visible conversation (R184-3 remainder) | implementer | Cache fails closed on zero user/assistant counts; CLI preserves malformed identity failures but returns `.noVisibleMessages` on zero user/assistant/tool counts; named `_repro`s. Remaining adapters stay later slices. | **DONE** 2026-08-13 — PR #365 at `main@06353931`. |
| 75 | ADAPTER-EMPTY-SESSION-001J | low | Copilot events with a valid session id but no user/assistant turns report malformed JSON (R184-3 remainder) | implementer | Empty session id remains `.malformedJSON`; valid-id zero-turn events return `.noVisibleMessages`; checkpoint discovery/fallback stays green; named `_repro`. Empty-session adapter series complete. | **DONE** 2026-08-13 — PR #366 at `main@98b01aea`. |
| 76 | ADAPTER-TAIL-TERMINAL-001 | low | Tail-parse treats `malformedJSON` / `invalidUtf8` / `fileMissing` as terminal while full parse retries them (R184-4) | implementer | `isTerminalTailFailure` delegates to `FileIndexState.isTerminalFailure`; malformed tail falls through to full scan; `noVisibleMessages` stays terminal; named `_repro`s | **DONE** 2026-08-13 — PR #368 at `main@90256cc5`. |
| 77 | ADAPTER-TRUNCATION-METADATA-001 | low | Cline inherits default `streamMessagesWithMetadata` and silently omits truncation on oversized whole-transcript reads | implementer | Override reports `truncatedAt` / `totalKnownComplete=false` when message count exceeds `ParserLimits.maxMessages`; named `_repro`. Remaining adapters stay later slices. | **DONE** 2026-08-14 — PR #370 at `main@64253c1a`. |
| 78 | ADAPTER-TRUNCATION-METADATA-001B | low | VS Code inherits default `streamMessagesWithMetadata` and silently omits truncation on oversized whole-transcript reads | implementer | Override reports `truncatedAt` / `totalKnownComplete=false` when message count exceeds `ParserLimits.maxMessages`; named `_repro`. Cursor and Gemini CLI stay later slices. | **THIS PR** — #371 |
| 48 | TODO-REL-1.0.5 | release | Notarize/publish v1.0.5 | human | Human auth in TODO + notarization | **BLOCKED** |

Evidence for CURSOR-CWD-001: `docs/followups.md:52,67` (B3 partial; must not infer from unrelated file selection); adapter `macos/Shared/EngramCore/Adapters/Sources/CursorAdapter.swift`.

Evidence for RECLAMATION-ABORT-001: `executeCycle` now isolates recovery,
eligible-plan, and CAS-eviction item failures while leaving cycle-level catalog
snapshot/evaluation/cursor failures fail-closed
(`macos/EngramService/Core/ArchiveReclamationCoordinator.swift:144-267`). A
failed eligible operation locks the cursor frontier, so later successes cannot
hide the failed row (`:192-239`). Recovery continuation, cursor fairness, and
CAS continuation are executable in
`macos/EngramServiceCoreTests/ArchiveReclamationCoordinatorTests.swift:212-415`.
Audit L5 in `docs/reviews/2026-07-17-engram-full-audit.md:285`.

### MCP-001 post-#215 re-verification (`main@7f053706`)

The [MCP 2025-11-25 schema](https://modelcontextprotocol.io/specification/2025-11-25/schema)
defines `CallToolResult.structuredContent` as an optional JSON object. The
original violating producer now returns `{ "aliases": [...] }`
(`macos/EngramMCP/Core/MCPDatabase.swift:1591-1607`), and the shipped route
passes it through `toolSuccess`
(`macos/EngramMCP/Core/MCPToolRegistry.swift:1153-1170`).

All 27 current Swift `toolSuccess` call sites were inspected. Every shipped
structured success producer is an explicit object, a formatter returning an
object, or an encoded Swift response object; the two success paths without
structured content use the allowed text-only response shape. The generic
wrapper remains visible at
`macos/EngramMCP/Core/MCPToolRegistry.swift:1825-1901`, but no current caller
passes it an array or scalar root.

Executable coverage checks every advertised output schema and all 15 tools
that declare one, plus the original alias-list regression and golden route
(`macos/EngramMCPTests/EngramMCPExecutableTests.swift:381-496,5095-5148`). The
golden itself has an object root
(`tests/fixtures/mcp-golden/manage_project_alias.list.json:8-23`); a static scan
of the current object-root MCP golden files found 24 `structuredContent`
payloads and zero non-object roots. Result: **PASS; MCP-001 is closed and no
production change is warranted.**

Evidence for ARCHIVE-DISCOVERY-001: Claude Code materializes a `Set` and sorts
it (`macos/Shared/EngramCore/Adapters/Sources/ClaudeCodeAdapter.swift:96-109`);
Codex recursively materializes and sorts every rollout locator
(`macos/Shared/EngramCore/Adapters/Sources/CodexAdapter.swift:503-514`); only
after `ArchiveCaptureCoordinator` has awaited and snapshotted those full lists
does its locator-budget loop begin
(`macos/EngramCoreWrite/ArchiveV2/ArchiveCaptureCoordinator.swift:430-506`).
The design adjudication confirms that truncating the existing array would
starve later locators and that the durable checkpoint does not contain the
full inventory; see
`docs/reviews/2026-08-12-archive-discovery-001-design-scope.md`.

Evidence for REMOTE-MANIFEST-SCHEMA-001: direct decode now throws the existing
`RemoteSyncError.schemaVersionUnsupported` contract and aggregate decode rejects
an unsupported envelope before reading its entries
(`macos/EngramCoreWrite/RemoteSync/ManifestCodec.swift`). Individual catalog
entries still decode independently, so an unsupported peer is skipped while a
current peer survives. Direct, envelope type/version, and mixed-peer behavior is pinned by
the named schema-version regression tests in
`macos/EngramCoreTests/RemoteSync/SessionSyncTests.swift`; the implementation
matches the fail-closed model already used by
`macos/EngramCoreWrite/RemoteSync/BundleCodec.swift:100-106`.

Evidence for REMOTE-TELEMETRY-001: every Archive V2 503 response represents
`storage_unavailable` (`macos/EngramRemoteServer/Core/ArchiveRoutes.swift:43,124,201,453`),
but the telemetry classifier recognizes only 507 and otherwise records a 5xx as
`internal_error`
(`macos/EngramRemoteServer/Core/ArchiveRemoteTelemetryStore.swift:161-180`).
The named service-unavailable regression lives in
`macos/EngramRemoteServerCoreTests/ArchiveRemoteTelemetryStoreTests.swift`.

### ARCH-001 A/B/C residual audit (`main@394269c9`)

Scope: literal, case-insensitive `hidden_at IS NULL` matches under the shipped
App, Service, and MCP Swift targets. A match is actionable only when the
surface is a default list/browse/KPI and skip-tier rows can change its product
result. Search deliberately uses the stricter skip+lite policy; diagnostics,
hierarchy inspection, and mutation guards do not inherit list-visible
semantics.

| File:line | Classification | Evidence / disposition |
|-----------|----------------|------------------------|
| `macos/Engram/Core/Database.swift:515,543,577,640` | intentional search | FTS and LIKE keyword paths also exclude both `skip` and `lite`; do not replace with the list-visible predicate, which keeps `lite`. |
| `macos/Engram/Core/Database.swift:1200` | intentional diagnostic | `tierDistribution` must retain visible `skip` rows to report its explicit `skip` bucket. |
| `macos/Engram/Core/Database.swift:1385,1397,1414,1431,1494,1515` | intentional includeHidden / hierarchy diagnostic | Child, suggestion, and Agents-page counts intentionally inspect skip-tier subagent rows; `includeHidden` controls manual-hidden rows, not child-tier visibility. |
| `macos/EngramService/Core/EngramServiceReadProvider.swift:610,679,919` | intentional search | LIKE, FTS, and semantic candidates pair the hidden predicate with `SessionSemanticSearchPolicy.searchableTierSQL`. |
| `macos/EngramService/Core/EngramServiceReadProvider.swift:1014` | intentional diagnostic | Raw per-source `sessionCount` includes skip by contract; coverage numerators and denominators separately use the list-visible/index-eligible population (`:1028-1039`). |
| `macos/EngramMCP/Core/MCPDatabase.swift:1408,2235,2286` | intentional search | Semantic, FTS, and LIKE paths pair the predicate with `SessionSemanticSearchPolicy.searchableTierSQL` (`:1410,2237,2288`). |
| `macos/EngramService/Core/EngramServiceCommandHandler.swift:1336,1527` | intentional mutation guard | Source-disable and hide-empty updates use the predicate only to make state changes idempotent; neither is a list/browse read. |
| `macos/EngramService/Core/EngramServiceCommandHandler.swift:1681,1687,1692` | intentional diagnostic | Hygiene inventories all visible empty/suggestion/orphan remediation candidates, including skip-tier records. |
| `macos/EngramService/Core/EngramServiceCommandHandler.swift:2430` | intentional filesystem inventory | `link_sessions` promises all AI session files for a project (`macos/EngramMCP/Core/MCPToolRegistry.swift:469`); hidden and orphan filters remain deliberate while skip files stay in scope. |

Result: **no actionable list/browse skip-inflation residual** was found in the
remaining literal matches. This closes the ARCH-001C residual sweep, not the
parent ARCH-001 structural debt named at rank 31.


Evidence for HOME-BADGE-001: Continue/Follow-ups already use
`min(count, todayPanelRowLimit)` for badges and `prefix(todayPanelRowLimit)` for
rows (`macos/Engram/Views/Pages/HomeView.swift` continue/follow-up sections), but
Changed Repos still used `badge: "\(projectGroups.count)"` with
`prefix(5)` (`changedReposSection`). Audit L16 in
`docs/reviews/2026-07-17-engram-full-audit.md`.

Evidence for LOGSTREAM-MODULES-001: `LogStreamView.reload` previously set
`availableModules` only when empty (`macos/Engram/Views/Observability/LogStreamView.swift`
around the first-load gate). Later OSLog/service categories never entered the
picker. Audit L33 in `docs/reviews/2026-07-17-engram-full-audit.md`.

Evidence for MCP-HYBRID-ZIP-001: hybrid fusion built `semanticById` via
`zip(semanticSessionIds, semanticItems)` (`MCPDatabase.swift`). `searchResultItems`
uses `compactMap` and can return fewer items than ids when a session row is gone,
so zip shifts labels. Service uses `semanticItems.map { ($0.id, $0) }`
(`EngramServiceReadProvider.swift:821`). Audit L30 in
`docs/reviews/2026-07-17-engram-full-audit.md`.



Evidence for REMOTE-STATUS-PERSIST-001: GET `/v2/archive/status` called
`telemetry.status(forcePersist: true)` (`ArchiveRoutes.swift`), and
`observed()` records the status request after the response, so the next poll
always found dirty state and rewrote `status-v1.json`. Audit L27 in
`docs/reviews/2026-07-17-engram-full-audit.md`.

Evidence for SESSION-DETAIL-FILTER-001: on `main@8c951673`, the full branch of
`SessionDetailView.updateDisplayIndexed` assigned
`indexedMessages.filter { ... }` directly on the calling actor
(`macos/Engram/Views/SessionDetailView.swift:100-123` before this change).
Classification and find-match scans were already detached, leaving this L32
visibility scan as the remaining 100k-row main-thread path. The implementation
uses a cancellable detached loop, a live session token before publication, and
keeps Load-more on the append-only slice (`SessionDetailView.swift:102-166`).

Evidence for SERVICE-CHECKPOINT-SHUTDOWN-001: the periodic PASSIVE checkpoint
task is created at `macos/EngramService/Core/EngramServiceRunner.swift:381-397`.
Graceful shutdown now cancels and awaits that task before awaiting startup
TRUNCATE and running final TRUNCATE (`:432-482`). Because the runner itself is
already cancelled on this path, final TRUNCATE also runs in an awaited fresh
task so the gate's cancellation check cannot reject it before SQLite executes.
The deterministic regressions hold a cancellation-insensitive checkpoint in
flight and exercise the final call from a cancelled parent
(`macos/EngramServiceCoreTests/EngramServiceIPCTests.swift:1623-1678`). Audit
L18 in `docs/reviews/2026-07-17-engram-full-audit.md`; the final-TRUNCATE
cancellation failure was reproduced by the existing runner cancellation test.
Shipped in PR #323 at `main@dc5a5128`.
## Post-#322 pipeline (audit lows)
| Rank | ID | Sev | Title | Status |
|------|----|-----|-------|--------|
| 40 | SERVICE-CHECKPOINT-SHUTDOWN-001 | low | Graceful shutdown awaits periodic WAL checkpoint | **DONE** PR #323 `main@dc5a5128` |
| 41 | REMOTE-CATALOG-MEM-001 | low | `/v1/catalog` unbounded in-memory peer manifests (L29) | **DONE** PR #325 `main@c9c6c7f9` |
| 43 | INDEXER-BACKPRESSURE-001 | low | Unbounded AsyncThrowingStream between scan and 100-row write batches (L17) | **DONE** PR #330 `main@53bd4cc4` |
| 44 | SUGGESTED-PARENT-RESCORE-001 | low | Detection-version bump leaves stale single suggestions unscored (L11) | **DONE** PR #331 `main@5ed938e4` |
| 45 | GEMINI-JSON-FSYNC-001 | low | Gemini projects.json writeAtomic skips temp/parent fsync (L26) | **DONE** PR #332 `main@b344fa56` |
| 46 | RECLAMATION-ABORT-001 | low | One item failure aborts remaining recovery/reclaim/CAS work (L5) | **DONE** PR #333 `main@069d19e0` |
| 47 | SESSION-DETAIL-FILTER-001 | low | Full loaded-prefix visibility filtering ran on the main actor (L32) | **DONE** PR #334 `main@54d0fce4` |
| 48 | BROWSE-SORT-INDEX-001 | low | Default updated-desc browse filesorts activity-time ordering (L9) | **DONE** PR #335 `main@88a1a2e0` |
| 49 | SCHEMA-TOOL-DEAD-001 | low | Uncalled EngramCoreSchemaTool target and scheme (L35) | **DONE** PR #336 `main@c39c0ac0` |
| 50 | FTS-H01-TS-001 | low | TS version-3 FTS finalize lacked the Swift H01 live-row copy/coverage guard (L20) | **DONE** PR #337 `main@dffb882f` |
| 51 | PERF-YML-DOCS-001 | low | Perf workflow non-gating policy was undocumented on the workflow (L22) | **DONE** PR #338 `main@2d9644aa` |
| 52 | DOCS-INDEX-RETENTION-001 | low | Archive and review evidence lacked scoped indexes and an explicit retention policy (L23) | **DONE** PR #339 `main@2aa7f84b` |
| 53 | MCP-STDIO-DEAD-001 | low | Unreachable second `tools/call` switch dispatch (L13) | **DONE** PR #340 `main@b3165b8b` |
| 54 | ADAPTER-STREAM-INJECTION-001 | low | Four adapter stream paths mislabeled injected wrappers as user (L10) | **DONE** PR #341 `main@2d6f3f27` |
| 55 | GEMINI-TOOL-EVENTS-001 | low | Gemini CLI metadata/stream paths dropped real tool events (L-b) | **DONE** PR #342 `main@2c405175` |
| 56 | WARP-TAB-0600-001 | low | Warp tab config written without forced 0600 (L-e / SEC-006) | **DONE** PR #343 `main@4804ac03` |
| 57 | ARCHIVE-SYNC-REFRESH-001 | low | Archive Sync status refresh failure was silent (L-d remainder) | **DONE** PR #344 `main@6cff11ef` |
| 58 | GET-CONTEXT-COST-TODAY-001 | low | `get_context` Cost today used UTC while `get_costs` uses local day (L-g) | **DONE** PR #345 `main@85d8d3c9` |
| 59 | TIMELINE-CONTENT-REFRESH-001 | low | Browse pages only reload when `totalSessions` changes (L-c) | **DONE** PR #346 `main@11c568f3` |
| 60 | DERIVEDDATA-RELEASE-PLAINTEXT-001 | low | DerivedData Release could persist API keys in plaintext settings (L-f) | **DONE** PR #347 `main@8a1a1451` |
| 61 | MCP-SEARCH-MIN-LENGTH-001 | low | MCP 1-char keyword search over-recalled vs app/service (L-a) | **DONE** PR #348 `main@444c5d6c` |
| 62 | ARCH-001D-PARITY | debt | First executable App/Service/MCP keyword-search parity fixture | **DONE** PR #351 `main@841ad4a8` |
| 63 | TS-SAFEMOVEDIR-CASE-001 | low | TS `safeMoveDir` lacked Swift M13 case-only rename exception (L-j) | **DONE** PR #353 `main@b74836bd` |
| 65 | SETTINGS-MAINACTOR-IO-001 | low | AI settings debounce still flocks/Keychain on MainActor (R9) | **IN PR** |
| 44 | TODO-REL-1.0.5 | release | Notarize/publish v1.0.5 | **BLOCKED** |
`docs/reviews/2026-07-17-engram-full-audit.md`.
