# Engram Follow-ups

Follow-ups are verification gaps, low-priority refactors, or items that need
real data, UI exercise, or product confirmation before becoming TODOs.

## OPS-ALIAS-001 — Prod path-shaped project_aliases cleanup (closed, 2026-07-21)

Authorized post-#228 service touch rewrote production `project_aliases` from
18 rows (10 path-shaped) to 15 basename-only rows. Backup
`~/.engram/backups/index.sqlite.before-alias-cleanup-20260721144628.bak`.
Verification write-up: `docs/verification/prod-alias-cleanup-2026-07-21.md`.
No further prod alias rewrite is planned; do not re-run without a fresh
inventory + backup.

## ALIAS-P2 — Same-basename different-parent ghost remove (open, low)

Codex residual on #228: a pathological full-path pair that normalizes to the
same basename self-key cannot be removed via `manage_project_alias` because
input normalize rejects equal keys before delete. Not observed in prod after
OPS-ALIAS-001. Fix only if a repro host reappears; prefer preventing path-
shaped inserts over special-case remove.

## UI-001 — Advanced session visibility controls (closed, #224)

Removed the Advanced Session Filter and Noise Details controls because they
only persisted local settings and never reached a product list predicate.
`sessions.showAll` remains the sole user-facing session-visibility control.

## Blind-audit implementation inventory (2026-07-19)

The closeout workflow completed 15/15 discovery scopes, explicitly named all
17 Swift sources, and adjudicated 23 canonical candidates: 22 confirmed and 1
refuted. KIMI-001 and WRITER-LOCATOR-001 retain document-scoped legacy
references; one duplicate MCP submission maps to the existing MCP-001 row.
MCP-001 was a confirmed MCP 2025-11-25 object-root violation at audit time; it
was fixed by #215 and passed a shipped-Swift post-merge re-verification on
2026-08-12.

The closeout's proposed regression names were specifications at adjudication
time, not execution evidence. A source with no retained finding was not proven
defect-free. CURSOR-CWD-001 now has an accepted deterministic
workspace-ownership contract and executable coverage on PR #305. This does not
close the repository-wide audit.

| Batch | Status | Confirmed IDs |
|-------|--------|---------------|
| **A1 — Codex parser and indexing integrity** | stacked PR #205 | ADAPTER-CODEX-001, ADAPTER-CODEX-002, IDX-PARTIAL-001 |
| **A2 — Kimi composite session correctness** | stacked PR #206 | KIMI-001, KIMI-002, KIMI-003 |
| **A3 — Qwen product integration** | stacked PR #207 | SRC-QWEN-001, SRC-QWEN-002 |
| **A4 — Adapter ingestion guardrails** | stacked PR #208 | ADAPTER-CC-001, SRC-COMMANDCODE-001, VSCODE-INCR-001 |
| **B1 — Composite-input discovery and invalidation** | stacked PR #209 | ADAPTER-GEMINI-001, COPILOT-AUX-001, COPILOT-DISCOVERY-001 |
| **B2 — OpenCode archive and byte accounting** | stacked PR #210 | ADAPTER-OPENCODE-001, ADAPTER-OPENCODE-002 |
| **B3 — Cursor content and ownership** | content in stacked PR #211; deterministic cwd ownership implemented on PR #305 | CURSOR-CONTENT-001, CURSOR-CWD-001 |
| **C1a — Archive V2 source-toggle convergence** | stacked PR #212 | SRC-001 |
| **C1b — Writer locator relocation** | stacked PR #213 | WRITER-LOCATOR-001 |
| **C1c — Startup parent-backfill pagination** | stacked PR #214 | PARENT-BACKFILL-STARVE-001 |
| **D1 — MCP result contract** | merged #215; post-merge re-verification PASS 2026-08-12 | MCP-001 |

Legacy references: KIMI-001 corresponds to `H08` only within
`2026-06-10-multi-expert-audit.md`, and WRITER-LOCATOR-001 corresponds to `L3`
only within `2026-07-17-engram-full-audit.md`. The duplicate MCP submission maps
to `MCP-001`. `AG-BYTES-001` is refuted by a 1–2 vote because Antigravity's
retained `pbSizeBytes` is the documented historical logical size of the complete
`.pb` session.

Each implementation-ready finding requires a failing regression, recorded RED,
minimum production fix, focused/full GREEN, and a fresh Codex `PASS` before
commit/push/stacked PR. CURSOR-CWD-001's accepted contract uses only a unique
per-workspace composer pointer and never infers authoritative project state
from an unrelated file selection. No automatic merge is authorized.

## Post-review residuals (2026-07-18 full-project review)

Promoted from `docs/reviews/2026-07-18-full-project-review.md` so open work is
not only a bare disposition status table. R2–R5 and R10 closed in #196 / R4+;
R1 remains open. R4 terminalization is limited to explicit input-local provider
rejection; HTTP/transport, malformed response, and dimension/config failures
remain recoverable and do not consume the permanent budget. Remaining items:

| ID | Status | Home / next step |
|----|--------|------------------|
| **R1** / ARCH-001 | open (structural investment; A/B/C/D shipped) | ARCH-001A shared search predicates (#311), ARCH-001B list/aggregate visibility convergence (#312), ARCH-001C residual list visibility (#313), and ARCH-001D keyword id parity (#351, `main@841ad4a8`) are on main. The remaining work is the full CoreRead pool/DTO migration; that deferred structural item keeps ARCH-001 open. |
| **MCP-001** | closed (#215; reverified 2026-08-12) | The shipped alias-list producer returns an object root (`macos/EngramMCP/Core/MCPDatabase.swift:1591-1607`), its route uses the shared success wrapper (`macos/EngramMCP/Core/MCPToolRegistry.swift:1153-1170`), and executable catalog/alias contracts plus the golden assert the object shape (`macos/EngramMCPTests/EngramMCPExecutableTests.swift:381-496,5095-5148`; `tests/fixtures/mcp-golden/manage_project_alias.list.json:8-23`). All 27 current Swift success-wrapper call sites were inspected; no non-object structured root remains. |
| **REMOTE-MANIFEST-SCHEMA-001** / L36 | closed (#317) | Direct and aggregate manifest decoders reject unsupported schema versions and types while preserving compatible catalog peers; shipped at `main@ecd13db0`. |
| **REMOTE-TELEMETRY-001** / L28 | closed (#318) | Archive 503 and 507 telemetry both map to `storage_unavailable`; shipped at `main@2ddaa7a2`. |
| **HOME-BADGE-001** / L16 | closed (#319) | Home Changed Repos badge clamps to `todayPanelRowLimit`; shipped at `main@7c158cdc`. |
| **LOGSTREAM-MODULES-001** / L33 | closed (#320) | LogStream module picker merges observed modules every reload; shipped at `main@ba7ffc8f`. |
| **MCP-HYBRID-ZIP-001** / L30 | closed (#321) | MCP hybrid fusion indexes semantic hits by `session.id` via `MCPSearchResultIndex` instead of positional `zip(ids, items)` when deleted sessions drop out of `searchResultItems`. |
| **REMOTE-STATUS-PERSIST-001** / L27 | closed (#322) | `/v2/archive/status` returns the live snapshot with `forcePersist: false` so polling no longer rewrites `status-v1.json` every request; disk flush stays on the 60s throttle. Shipped at `main@dcb2b3d9`. |
| **SERVICE-CHECKPOINT-SHUTDOWN-001** / L18 | closed (#323) | Graceful service shutdown cancels and awaits the periodic PASSIVE checkpoint before either remaining TRUNCATE operation. Final TRUNCATE runs in an awaited fresh cancellation context; shipped at `main@dc5a5128`. |
| **REMOTE-CATALOG-MEM-001** / L29 | closed (#325) | Legacy `/v1/catalog` stops after 1,024 matching peer manifests and limits both cumulative decoded input and the serialized response to 4 MiB; fail-closed 413 when over budget. Shipped at `main@c9c6c7f9`. |
| **TIMELINE-RECOMPUTE-001** / L14 | closed (#329) | TimelinePageView materializes derived collections once per body evaluation; shipped at `main@8c951673`. |
| **SESSION-DETAIL-FILTER-001** / L32 | closed (#334) | `SessionDetailView.updateDisplayIndexed` runs its full loaded-prefix visibility loop in cancellable detached work; shipped at `main@54d0fce4`. |
| **FTS-H01-TS-001** / L20 | closed (#337) | Retained TypeScript version-3 finalize copies eligible live FTS rows and refuses an incomplete swap; shipped at `main@dffb882f`. |
| **PERF-YML-DOCS-001** / L22 | closed (#338) | `.github/workflows/perf.yml:1` documents that the workflow is nightly/`workflow_dispatch` only and is not a pull-request or merge gate. Shipped at `main@2d9644aa`. |
| **DOCS-INDEX-RETENTION-001** / L23 | closed (#339) | `docs/archive/README.md` and `docs/reviews/README.md` provide scoped navigation, current-authority boundaries, and explicit no-age-only-deletion retention rules. Shipped at `main@2aa7f84b`. |
| **SUGGESTED-PARENT-RESCORE-001** / L11 | closed (#331) | detection version bump clears stale suggested parents; shipped at `main@5ed938e4`. |
| **POLYCLI-LINKED-DEAD-001** / L12 | closed (#326) | dead polycli linked accounting removed; shipped at `main@15eea454`. |
| **WORKGRAPH-FORMATTER-001** / L15 | closed (#324) | WorkGraph uses EngramTimestampParser; shipped at `main@53c171d1`. |
| **INDEXER-BACKPRESSURE-001** / L17 | closed (#330) | indexAll awaits full 100-snapshot writes; shipped at `main@53bd4cc4`. |
| **POLYCLI-LINKED-DEAD-001** / L12 | closed (#326) | dead polycli linked accounting removed; shipped at `main@15eea454`. |
| **ANTIGRAVITY-CWD-REREAD-001** / L34 | closed (#327) | Antigravity CWD inference reads at most 50KB; shipped at `main@ddf2070a`. |
| **VSCODE-STRICT-REQUESTS-001** / L24 | closed (#328) | VS Code ignores stable non-object request entries; shipped at `main@5c5e916b`. |
| **GEMINI-JSON-FSYNC-001** / L26 | closed (#332) | `GeminiProjectsJSON.writeAtomic` fsyncs the temp file before rename and the parent directory after, matching `JsonlPatch`. Shipped at `main@b344fa56`. |
| **RECLAMATION-ABORT-001** / L5 | closed (#333) | Archive reclamation contains recover, eligible-plan, and CAS-evict failures per item, continues later work in the same accepted cycle, preserves cancellation, and does not advance its cursor beyond a failed eligible candidate. Shipped at `main@069d19e0`. |
| **BROWSE-SORT-INDEX-001** / L9 | closed (#335) | The list-visible activity-time index in `macos/EngramCoreWrite/Database/EngramMigrations.swift:63` serves `ORDER BY COALESCE(end_time, start_time)` without a temporary B-tree; `MigrationRunnerTests.swift:158` pins the fresh-migration query plan. Shipped at `main@88a1a2e0`. |
| **SCHEMA-TOOL-DEAD-001** / L35 | closed (#336) | Removed the uncalled `EngramCoreSchemaTool` sources, XcodeGen target, and generated target/scheme. Shipped at `main@c39c0ac0`. |
| **MCP-STDIO-DEAD-001** / L13 | closed (#340) | `MCPStdioServer.swift:109-113` remains the sole live `tools/call` dispatch and the unreachable `handle()` switch case is removed. Shipped at `main@b3165b8b`. |
| **ADAPTER-STREAM-INJECTION-001** / L10 | closed (#341) | CommandCode, Qwen, Qoder, and Iflow streaming reuse their batch-path injection classifiers, emit injected wrappers as system, and preserve the real first-user summary/count. Shipped at `main@2d6f3f27`. |
| **GEMINI-TOOL-EVENTS-001** / L-b | closed (#342) | Gemini CLI batch counts and streamed messages now share one normalizer for persisted `toolCalls[]`, inline `functionCall`, and the retained legacy `Tool call:` fixture shape. Shipped at `main@2c405175`. |
| **WARP-TAB-0600-001** / L-e | closed (#343) | Warp resume tab configs are written through `writeWarpTabConfigFile`, which forces POSIX 0600 after the atomic write. Shipped at `main@4804ac03`. |
| **ARCHIVE-SYNC-REFRESH-001** / L-d | closed (#344) | A current-generation Archive Sync status failure now clears stale status and reports the localized error through the existing user-visible settings message; `reportError: false` preserves Save/Run/Drill outcomes. Shipped at `main@6cff11ef`. |
| **GET-CONTEXT-COST-TODAY-001** / L-g | closed (#345) | `get_context` Cost today uses `contextTimeZone()` (`TZ` or `.autoupdatingCurrent`) so the local calendar day matches `get_costs` `date(..., 'localtime')`. Rolling 7d/24h windows stay UTC. Named `_repro` plus a UTC isolation check live in `EngramMCPExecutableTests`. Shipped at `main@85d8d3c9`. |
| **TIMELINE-CONTENT-REFRESH-001** / L-c | closed (#346) | Browse pages now key reload work on a status token that changes after content-only scans instead of relying only on `totalSessions`. Shipped at `main@11c568f3`. |
| **DERIVEDDATA-RELEASE-PLAINTEXT-001** / L-f | closed (#347) | `KeychainHelper.shouldBypassKeychain` retains its DEBUG/DerivedData authorization-dialog policy, while `allowsPlaintextSettingsFallback` is independently true only in DEBUG. Release builds, including DerivedData Release, keep the SEC-M3 fail-closed `@keychain` marker path. Shipped at `main@8a1a1451`. |
| **MCP-SEARCH-MIN-LENGTH-001** / L-a | closed (#348) | `MCPDatabase.searchSessions` returns empty keyword results when `normalizedQuery.count < 2`, matching app/service (`Database.swift:568`, `EngramServiceReadProvider.swift:530`). Two-character Latin still uses LIKE. Multi-word session-scoped AND remains READ-001. Shipped at `main@444c5d6c`. |
| **READ-001/002/003** | closed (post-audit follow-up) | MCP multi-term session-scoped AND, activity-time `since`, and exact project-or-alias filtering are covered by executable `_repro` tests; this does not close ARCH-001 |
| **R4-dual-tx / EMB-009** | closed (#223) | Shipped insight backfill writes success vectors and item-failure accounting in one `writer.write`; successful rows set `insights.has_embedding=1`; the shipped-runner `_repro` forces failure accounting to throw and proves vector/flag rollback without changing R4 terminal taxonomy |
| **MCP-002** | closed (#225) | `get_context`, `tool_analytics`, and `file_activity` now reuse shared list-visible and top-level predicates; shipped-binary `_repro` coverage includes `listContextSessions`, `topToolsSince`, and `fileHotspotsSince`. Existing READ-005 `orphan_status` behavior is unchanged. |
| **MCP-012** | closed (#225) | `project_timeline` now excludes hidden, skip-tier, confirmed-child, and suggested-child sessions, with shipped-binary `_repro` coverage against `list_sessions` defaults. |
| **R6** | accepted residual (redesign deferred) | Producer intentionally holds the writer gate for the full FS+patch lifetime (finding 8 integrity). M1 prevents false timeouts; availability redesign (release gate across network/FS phases like remote offload) is product-scale work, not a defect fix |
| **R7** | closed (#220) | Offload HTTP matches Archive V2 transport depth (ephemeral session, redirect reject, size caps, post-DNS private check for named private hosts); requireTLS product default fail-closed docs fixed |
| **SEC-001** | closed (#226) | Auto-offload treats remote HEAD as a soft optimization: absent objects require a successful PUT, while existing objects require GET + bundle decode + exact expected content-hash match before `commitOffloaded` may collapse local FTS; both shipped call paths have `_repro` coverage |
| **R8** | closed (#218) | Durable `content_fingerprint` enables parity-stable `mergeTailSnapshot` for Claude/Codex user-led appends; covered by `testCodexTailMergeMatchesFullReindex_repro` + updated Claude tail parity |
| **R9** / M21 residual | closed (#219 flush; #356 off-main persist) | AI settings flush pending debounce on disappear; Keychain + settings.json persist now run off-main via `AISettingsPersister` after a MainActor snapshot. Shipped at `main@434892f0`. |
| **R11 ledger** | closed | Disposition evidence columns + this followups section |
| **F5-CI** | closed (#222) | `.github/workflows/test.yml` now treats `npm audit --audit-level=moderate` as soft-fail for both pull requests and pushes, so merge cannot change audit policy from soft to strict. |
| **TS-SAFEMOVEDIR-CASE-001** / L-j | closed (#353) | TypeScript `safeMoveDir` treats same-realpath destinations as a case-only rename, matching Swift M13 (`FsOps.swift:154-187`). Product moves remain Swift. Shipped at `main@b74836bd`. |
| **REPO-DISCOVERY-COOLDOWN-001** / F3 | closed (#355) | `RepoDiscoveryMaintenanceThrottle.selectCandidates` no longer writes the 6h success window. Failed git probes (`macos/EngramCoreWrite/Indexing/RepoDiscovery.swift` `probeRepositoriesDetailed`) record a 15-minute failure cooldown via `recordOutcomes`; only successful probes burn the success window. Named `_repro`s live in `ServiceTelemetryTests` and `RepoDiscoveryTests`. Shipped at `main@9090e16d`. |
| **ADAPTER-EMPTY-SESSION-001** / R184-3 | closed (#357 Codex slice) | Codex metadata-only files return `.noVisibleMessages`. Shipped at `main@c8c42b64`. |
| **ADAPTER-EMPTY-SESSION-001B** / R184-3 | closed (#358) | CommandCode and Iflow injection-only files return `.noVisibleMessages` after a valid session id. Shipped at `main@237aa757`. |
| **ADAPTER-EMPTY-SESSION-001C** / R184-3 | closed (#359) | Gemini empty/content-less files and Qoder injection-only files return `.noVisibleMessages`. Shipped at `main@43ca14bc`. |
| **ADAPTER-EMPTY-SESSION-001D** / R184-3 | closed (#360) | Cursor composers with no visible bubbles return `.noVisibleMessages`. Shipped at `main@871e2a12`. |
| **ADAPTER-EMPTY-SESSION-001E** / R184-3 | closed (#361) | Kimi wire/context metadata with no conversation turns returns `.noVisibleMessages`. Shipped at `main@a6a2348b`. |
| **ADAPTER-EMPTY-SESSION-001F** / R184-3 | closed (#362) | Timestamped Cline metadata-only files return `.noVisibleMessages`. Shipped at `main@7d40c1ad`. |
| **ADAPTER-EMPTY-SESSION-001G** / R184-3 | closed (#363) | OpenCode live sessions with no contentful text parts return `.noVisibleMessages`. Shipped at `main@fc5c70d4`. |
| **ADAPTER-EMPTY-SESSION-001H** / R184-3 | closed (#364) | Windsurf metadata-only Cascade cache files return `.noVisibleMessages`. Shipped at `main@1e3c610e`. |
| **ADAPTER-EMPTY-SESSION-001I** / R184-3 | closed (#365) | Antigravity metadata-only Cascade cache files and valid-id CLI transcripts with no user/assistant/tool turns return `.noVisibleMessages`. Shipped at `main@06353931`. |
| **ADAPTER-EMPTY-SESSION-001J** / R184-3 | closed (#366) | Copilot events with a valid session id but no user/assistant turns return `.noVisibleMessages`. Empty-session adapter series complete. Shipped at `main@98b01aea`. |
| **ADAPTER-TAIL-TERMINAL-001** / R184-4 | closed (#368) | Tail-parse terminal policy matches `FileIndexState.isTerminalFailure`. `malformedJSON` / `invalidUtf8` / `fileMissing` fall through to a full scan; `noVisibleMessages` stays terminal. Shipped at `main@90256cc5`. |
| **ADAPTER-TRUNCATION-METADATA-001** / export P1 remainder | closed (#370) | Cline whole-transcript reads report `truncatedAt` / `totalKnownComplete=false` when they exceed `ParserLimits.maxMessages`. Shipped at `main@64253c1a`. |
| **ADAPTER-TRUNCATION-METADATA-001B** / export P1 remainder | closed (#371) | VS Code whole-transcript reads report `truncatedAt` / `totalKnownComplete=false` when they exceed `ParserLimits.maxMessages`. Shipped at `main@ffec248e`. |
| **ADAPTER-TRUNCATION-METADATA-001C** / export P1 remainder | closed (#372) | Cursor whole-transcript reads report `truncatedAt` / `totalKnownComplete=false` when they exceed `ParserLimits.maxMessages`. Shipped at `main@8bb95e56`. |
| **ADAPTER-TRUNCATION-METADATA-001D** / export P1 remainder | closed (#373) | Gemini CLI whole-transcript reads report `truncatedAt` / `totalKnownComplete=false` when they exceed `ParserLimits.maxMessages`. Shipped at `main@eaecb430`. |
| **ADAPTER-TRUNCATION-METADATA-001E** / export P1 remainder | closed (#375) | Copilot checkpoint `index.md` whole-transcript reads report `truncatedAt` / `totalKnownComplete=false` when they exceed `ParserLimits.maxMessages`. Shipped at `main@9cac0311`. |
| **ADAPTER-TRUNCATION-METADATA-001F** / export P1 remainder | closed (#377) | `RecentlyModifiedSessionAdapter` forwards `streamMessagesWithMetadata` so a recent-scan wrap keeps the base adapter's `truncatedAt` / `totalKnownComplete=false`. Truncation-metadata adapter series complete, including recent-scan wrappers. Shipped at `main@b0d399a0`. |
| **ADAPTER-INDEX-CAP-001** / export P1 remainder | closed (#379) | Default `scanForIndexing` returns `.messageLimitExceeded` when `streamMessagesWithMetadata` reports truncation, instead of indexing a silently truncated prefix. Shipped at `main@11dfdaaa`. |
| **ADAPTER-INDEX-FTS-CAP-001** / export P1 remainder | closed (#381) | FTS drain uses `streamMessagesWithMetadata` and fails closed when the adapter reports truncation, instead of completing keyword coverage on a silent prefix. Shipped at `main@74f5dccf`. |
| **ADAPTER-INDEX-BACKFILL-CAP-001** / export P1 remainder | closed (#383) | Instruction and implementation-beat backfill use `streamMessagesWithMetadata` and fail closed when the adapter reports truncation, instead of writing prefix counts/beats as complete. Shipped at `main@4a63385d`. |
| **ADAPTER-MCP-FULLREAD-CAP-001** / export P1 remainder | closed (#385) | `MCPTranscriptReader.readMessages` / `readWithAdapterRegistry` throw `.messageLimitExceeded` when the adapter reports truncation, instead of returning a capped prefix as a complete array. Shipped at `main@c52fb157`. |
| **ADAPTER-PARSEINFO-CAP-001** / export P1 remainder | closed (#387) | Claude `parseSessionInfo` passes `reportFailures: true` so an oversized transcript returns `.messageLimitExceeded` instead of prefix counts. Shipped at `main@eddec1df`. Remaining JSONL adapters stay later slices. |
| **ADAPTER-PARSEINFO-CAP-001B** / export P1 remainder | closed (#389) | Codex `parseSessionInfo` passes `reportFailures: true` so an oversized transcript returns `.messageLimitExceeded` instead of prefix counts. Shipped at `main@57979e46`. Remaining JSONL adapters stay later slices. |
| **ADAPTER-PARSEINFO-CAP-001C** / export P1 remainder | closed (#391) | Qwen `parseSessionInfo` passes `reportFailures: true` so an oversized transcript returns `.messageLimitExceeded` instead of prefix counts. Shipped at `main@f022de0b`. Remaining JSONL adapters stay later slices. |
| **ADAPTER-PARSEINFO-CAP-001D** / export P1 remainder | closed (#393) | Iflow `parseSessionInfo` passes `reportFailures: true` so an oversized transcript returns `.messageLimitExceeded` instead of prefix counts. Shipped at `main@24c96146`. Remaining JSONL adapters stay later slices. |
| **ADAPTER-PARSEINFO-CAP-001E** / export P1 remainder | closed (#395) | CommandCode `parseSessionInfo` passes `reportFailures: true` so an oversized transcript returns `.messageLimitExceeded` instead of prefix counts. Shipped at `main@4d85c959`. Remaining JSONL adapters stay later slices. |
| **ADAPTER-PARSEINFO-CAP-001F** / export P1 remainder | closed (#397) | Qoder `parseSessionInfo` passes `reportFailures: true` so an oversized transcript returns `.messageLimitExceeded` instead of prefix counts. Shipped at `main@d9f7acfe`. Remaining JSONL adapters stay later slices. |
| **ADAPTER-PARSEINFO-CAP-001G** / export P1 remainder | closed (#399) | Copilot `parseSessionInfo` passes `reportFailures: true` so an oversized `events.jsonl` returns `.messageLimitExceeded` instead of prefix counts. Shipped at `main@a127abeb`. Remaining JSONL adapters stay later slices (Windsurf, Antigravity). |
| **ADAPTER-PARSEINFO-CAP-001H** / export P1 remainder | closed (#401) | Windsurf `parseSessionInfo` passes `reportFailures: true` so an oversized Cascade cache returns `.messageLimitExceeded` instead of prefix counts. Shipped at `main@844225de`. Remaining JSONL adapter: Antigravity. |
| **ADAPTER-PARSEINFO-CAP-001I** / export P1 remainder | closed (#403) | Antigravity cache and CLI `parseSessionInfo` pass `reportFailures: true` so oversized transcripts return `.messageLimitExceeded` instead of prefix counts. Shipped at `main@a157d21d`. Remaining JSONL adapter: Kimi. |
| **L-a…L-j** | residual | Remaining Low/Info row from the full-project review: L-h (blocked 1.0.5). L-b/#342, L-e/#343, L-d/#344, L-g/#345, L-c/#346, L-f/#347, L-a/#348, L-i/#349, L-j/#353 closed. |
| **SEC-M5 / I1 / I2** | design residual | See `docs/reviews/2026-07-17-accepted-residuals.md` |

Also see disposition inventory: `docs/reviews/2026-07-17-finding-disposition.md`.

## Open conditional follow-ups — exact-source archive v2 (2026-07-15)

These boundaries are deliberately outside the current operator deployment and
are not implementation-ready blockers for its operational closeout:

- **Restart-stable bounded locator discovery.** Current Claude Code and Codex
  discovery is cooperative-cancellable but O(N) and materializes/sorts the
  current locator set before `batchSize` applies. A future design needs a
  durable locator inventory/work queue, normally bootstrapped by one explicit
  full crawl and maintained with FSEvents. Do not claim discovery itself is
  bounded until that implementation and restart tests exist. This is tracked
  as `ARCHIVE-DISCOVERY-001` at stewardship rank 33: the current materialization
  is at `macos/Shared/EngramCore/Adapters/Sources/ClaudeCodeAdapter.swift:96-109`
  and `macos/Shared/EngramCore/Adapters/Sources/CodexAdapter.swift:503-514`,
  while `macos/EngramCoreWrite/ArchiveV2/ArchiveCaptureCoordinator.swift:430-506`
  applies its locator budget only after both full-list enumeration and
  snapshotting. Current-main adjudication found no safe prefix/limit patch:
  restart correctness requires a durable inventory plus an event-loss contract.
  The implementation boundary, rejected shortcuts, and executable Done-when are
  recorded in
  `docs/reviews/2026-08-12-archive-discovery-001-design-scope.md`; stewardship
  rank 33 is design-ready but implementation-deferred.
- **Canonical exporters for additional adapters.** Keep virtual, composite,
  adjacent-shard, path-sensitive, and database-backed locators unsupported
  until each adapter declares a complete canonical source set and passes a
  delete-original/replay-equivalence fixture. Regular-file shape alone is not
  sufficient.
- **Remote archive erasure or server-side GC.** The current v2 remote API is
  immutable and every DELETE remains `405`. Any future erasure/GC needs a
  separate design, explicit authorization, independent backup/key recovery,
  fresh two-site restore evidence, and a deletion safety review.

Reconciled from the first-release boundary: opt-in local source reclamation and
local CAS eviction are now implemented and operator-enabled. They are gated by
dual receipts, current per-replica recovery leases, generation revalidation,
and write-ahead quarantine, so they are no longer an open follow-up. They do not
authorize remote deletion or GC.

## Historical engineering-zero status (2026-07-11, Wave 8 Round 4)

**Open implementation-ready engineering follow-ups: 0.**

Wave 8 merged on main through `c983a759` closed the actionable perceived-duration
items (export progress, long project migrations), disk-audit consumer evidence,
and ignore-rule classification. Product-decision items already live in
`docs/roadmap.md` Decision pending (exactly 12 rows). Conditional UX that is not
currently exposed (FTS full-rebuild progress) is recorded as closed/deferred
below, not as open engineering work.

This remains the follow-up count, not the total delivery count: on 2026-07-15
the owner selected one implementation-ready public macOS release baseline in
`docs/TODO.md`. It is a scheduled delivery rather than a follow-up and does not
reopen any Wave 7 defect.

Evidence ledger:
`docs/reviews/2026-07-10-wave7-engineering-zero-closeout.md`.

## Closed — Wave 8 perceived-duration + ops (2026-07-10/11)

CLOSEOUT (2026-07-11): actionable items from the 2026-07-08 perceived-duration
audit and related ops follow-ups.

- **Session export in-flight feedback.** Closed across every exposed app entry:
  Wave 8C / H12 (`262d59a2` / `cfed29b5`) added the command-palette state
  machine; the final Task 7 remediation extended the same
  idle→inFlight→succeeded|failed contract to Sessions and Timeline rows, with
  visible progress, duplicate-export disable, and Finder reveal. Evidence:
  `CommandPaletteTests` and `SessionActionsTests` export-state/wiring suites.
- **Long project migrations cancel or continue.** Closed via Wave 8D
  (`c983a759` / `eeab26a8`): stable operation ID, cancel-before-commit,
  post-commit reconnect/continuation (not false cancellation), idempotent
  re-submit. Evidence: ProjectMove Core/Service/App long-op suites.
- **Disk-audit advisory access counters.** Closed via Wave 8E
  (`c87fab56` / `f1486c2f`): product read paths already update
  `last_accessed_at` / `access_count`; E2E consumer coverage in
  `EngramMCPExecutableTests.testGetMemoryRanksByServiceRecordedAccessCount_diskAuditConsumer`.
- **Normalize local ignore rules.** Closed: universal generated artifacts already
  live in shared `.gitignore` (`node_modules/`, `dist/`, `.husky/_/`). Remaining
  `.git/info/exclude` entries are host-local by design and stay uncommitted.
- **FTS full-rebuild progress UI.** Closed as not implementation-ready. Command
  palette still excludes `reindex`/`triggerSync`; aggregate index-job coverage
  remains the only surface. Reopen only if product exposes a user-visible full
  rebuild action.

## Closed — plan-completion product decisions moved to roadmap (2026-07-11)

CLOSEOUT (2026-07-11): these were never wave-6 implementation tasks; they remain
product decisions in `docs/roadmap.md` Decision pending (do not re-open here).

- **Sources-sync-3 nav consolidation** — roadmap row (alignment design deferred).
- **`ai_audit_log` desensitization design** — roadmap row (design-before-writer).

## Closed — provider-audit branch (2026-07-09)


CLOSEOUT (2026-07-09): **Resolve preserved `codex-provider-audit-remediation`
branch.**

- Reconciliation doc landed (PR #144) and is committed as
  `docs/reviews/provider-audit-branch-reconciliation-2026-07.md`.
- Branch deleted local + origin on 2026-07-09 after third-model (Grok)
  adjudication following Claude + Codex review.
- Tip preserved as annotated archive tag
  `archive/codex-provider-audit-remediation` (`285453d7`, pushed to origin).
- Deliberately-unported valuable features remain inventoried in the
  reconciliation doc and the roadmap Decision pending table; do not resurrect
  the branch name for new work.

Closed during the 2026-07-06 sync: documentation archive cleanup was already
committed; immediate Time Machine snapshot reclamation is no longer needed
(`df -h .` shows 241Gi available on 2026-07-06, so macOS can manage snapshots
normally).

## Completed — feature-cut execution plan, adjudicated Top 10 (2026-07-05)

CLOSEOUT (2026-07-06): items 0-10 completed in PR #103-#112, then LOW residual
cleanup completed in PR #113 (`24cc4562`). PR #113 and main `24cc4562` both had
Tests + CodeQL green. This section is retained as the historical execution
protocol and evidence trail; it is no longer active backlog.

Historical blocker (2026-07-05, RESOLVED 2026-07-06 by Claude): stopped at ITEM 0 /
PR #103 after the protocol's "CI stays red after 2 fix attempts" gate fired.
PR head `e903a06e` passed everything except `ui-test-full`, where only
`settings_dark` failed (`SSIM=0.8982` vs 0.91 threshold; `pHash=6` and
`diff=4.7001%` were within limits). Root cause: the checked-in baseline
`macos/EngramUITests/baselines/settings_dark.png` was stale — a
Chinese-locale capture last touched in `322f5095`, predating the forced
`-AppleLanguages (en)` in `TestLaunchConfig`, and still showing the Web UI /
MCP HTTP endpoint rows this PR deletes. It had only ever passed marginally
(SSIM 0.9157 on the last green main run); the PR's intentional settings
change pushed it below threshold. Fixed by refreshing the baseline from CI
run `28745689659`'s actual capture. Not a product regression. Related: main
HEAD `30e3a4af` is independently red on `swift-unit`
(`testPopoverStatusLabelsServiceInsteadOfMcpWhenUsingServiceStatus` expects
the popover Service chip that `30e3a4af` removed); this PR already carries
the aligned scan test (`d77e1ffa`), so merging ITEM 0 also restores main to
green.

Original goal for Codex: execute the cuts below. Provenance: a 38-agent opus+sonnet
workflow (4-area inventory → 4-lens propose → dedup → adversarial verify per
candidate: refuter + blast-radius → opus final ranking), merged with Codex's
own 2026-07-05 "hide/downgrade defaults" round. Every DELETE item survived
double adversarial verification; items 9-10 are product-default demotions the
owner explicitly approved in-session (2026-07-05).

Historical execution protocol (updated 2026-07-05, owner-approved AUTONOMOUS mode —
supersedes the earlier "Claude reviews before merge" gate):

- Run fully autonomously through STEP 0 and items 0-10 IN ORDER, one PR at a
  time, merged before the next starts (items share test files).
- Self-review replaces the Claude gate. After implementing each item, spawn
  independent review sub-agents covering at least: (a) line-by-line diff
  correctness; (b) removed-behavior audit — did any RETAINED behavior lose
  test coverage (the exact class of miss found in PR #103: deleting a test
  file silently uncovered the live redaction pattern matrix); (c) orphan
  tracer — grep the post-change tree for orphans the change created:
  project.yml/package deps, settings.json keys (add newly-dead keys to the
  SettingsView.saveAdvancedSettings scrub), on-disk artifacts (token/cache
  files needing one-time startup cleanup), Localizable.xcstrings keys,
  stale comments justifying retained code via deleted features, and
  followups/docs line anchors. Adversarially verify each finding before
  acting; fix CONFIRMED findings pre-merge; record findings + outcomes in
  the PR description.
- Tombstone tests: each deleted surface gets ONE negative-assertion owner
  per source file — never duplicate the same forbidden-string scan across
  suites (PR #103 finding 5).
- Merge gates per PR: CI green; self-review findings fixed or explicitly
  deferred with reasons in the PR description; matching CHANGELOG.md entry;
  the doc trims for that item done in the same PR; mark the item done in
  this file.
- STOP AND FILE A BLOCKER (do not improvise) if: CI stays red after 2 fix
  attempts; a review finding suggests deleting anything on a KEEP list; a
  destructive data migration seems needed; or an item's scope materially
  exceeds this plan. Record the blocker at the top of this section and move
  to the next item only if independent.

STEP 0 (before any merge): reconcile the main-checkout working tree.
Inspect `git status`/`git diff` — expected: (a) doc/plan files (CHANGELOG.md,
MEMO.md, docs/followups.md, .memory) carrying this plan → commit as
`docs(plan): file feature-cut execution plan and decision records`; (b) Swift
popover/menubar modifications (MenuBarController, PopoverView,
GeneralSettingsSection, EngramServiceReadProvider, HomePopoverActionsTests,
PopoverScreen, PopoverSmokeTests, EngramServiceIPCTests) → run the focused
suites (HomePopoverActionsTests, EngramServiceIPCTests); if green and
coherent with the 2026-07-05 popover perf work, commit as a perf follow-up;
if not coherent, stash with a dated note here and continue. Then rebase
PR #103 if needed.

ITEM 0 — DONE in PR #103: finish PR #103 (Delete HTTP transcript web UI). Apply the review at
https://github.com/bbingz/engram/pull/103#issuecomment-4886389830 —
4 REQUIRED: (1) port `testRedactionCoversCommonTokenFamilies` +
`testRedactionStaticPatternsProduceByteIdenticalOutput` from deleted
EngramWebUIServerTests into EngramServiceCoreTests targeting
`TranscriptExportService.redactSensitiveContent` (5 of 8 secret families
currently uncovered); (2) add `settings.removeValue(forKey: "webUIEnabled")`
to the SettingsView.saveAdvancedSettings scrub (~:452-457); (3) remove the
orphaned Hummingbird dep from EngramServiceCore in macos/project.yml
(~:113-114) + `xcodegen generate` (app-target dep at ~:168-169 is
pre-existing dead — optional bonus); (4) one-time startup cleanup
`try? FileManager.default.removeItem(at: runtimeDirectory
.appendingPathComponent("webui.token"))`. 4 RECOMMENDED: consolidate the
tombstone scans to one owner per source file; legacy transcript-pager comments
now name live consumers; the orphaned unavailable localization key was removed;
the perf-section EngramWebUIServer anchors in this file are annotated as
resolved-by-deletion (PR #103). Then self-review, merge, and proceed to item 2
(item 1 == this PR).

Ground rules:

- Land or stash the uncommitted perf working tree FIRST (it touches
  `PopoverView.swift`, `MenuBarController.swift`, `HomePopoverActionsTests`,
  which collide with item 1).
- One PR per numbered item; item 2 MUST be its own PR (~11K LOC).
- Repo test rule applies: delete a feature's tests in the same PR; behavior
  changes need matching Swift tests. Run `xcodegen generate` after
  adding/removing Swift files; `npm run lint` must pass.
- Items 1 and 4 both touch `EngramServiceIPCTests.swift`,
  `SettingsHonestyTests.swift`, `AppSearchServiceCutoverScanTests.swift` —
  if doing both, edit each shared test file once, not per-feature.
- No destructive DB migrations: leave orphaned tables (`mined_rules`,
  vector scaffolding) inert on installed DBs.
- Each cut carries its own doc trim (README/CLAUDE.md/docs/mcp-tools.md:
  MCP tool count, "Local Service Security" web-UI section, sources count).

1. **DONE in PR #103 — DELETE EngramWebUIServer (HTTP transcript web UI).** Remove
   `macos/EngramService/Core/EngramWebUIServer.swift` (761 LOC) +
   `EngramWebUIServerTests.swift` (629 LOC); strip
   `readWebUIEnabled`/`provisionWebToken`/`webTask`/`emitWebReady`/
   `ServiceWebErrorEvent` wiring from `EngramServiceRunner.swift`; remove the
   toggle/button/menu-item/status-tile in `NetworkSettingsSection.swift`,
   `GeneralSettingsSection.swift`, `MenuBarController.swift`,
   `Views/Pages/HomeView.swift`; drop `endpointHost`/`endpointPort`/
   `web_ready`/`web_error` from `EngramServiceStatusStore.swift`; fix
   scattered assertions in EngramServiceIPCTests/SettingsHonestyTests/
   HomePopoverActionsTests/EngramServiceStatusStoreTests. KEEP
   `TranscriptExportService` + `redactSensitiveContent` (used by
   get_session/export) and the Hummingbird SPM dependency
   (EngramRemoteServer uses it). Trim the CLAUDE.md "Local Service
   Security" web-UI paragraphs.
2. **DONE in PR #104 — DELETE legacy TS dev-server/entrypoint surface.** Remove
   `src/web.ts`, `src/web/routes/*`, `src/web/views.ts`, `src/index.ts`,
   `src/daemon.ts`, `src/core/lifecycle.ts`, `src/core/daemon-startup.ts`,
   plus daemon-exclusive orphans (candidates: `auto-summary`, `alert-rules`,
   `mock-data`, `daemon-client`, `git-probe`, `watcher` under `src/core/`)
   and their tests + `tests/web/`. The orphan list is ADVISORY — confirm each
   with `npm run knip`/grep before deleting; two prior passes disagreed on
   `src/core/sync.ts` and `tests/integration/`, so keep any test/module that
   covers retained code (`tests/web/hygiene.test.ts` likely stays). KEEP
   modules used by retained `src/tools/*` (config, monitor, live-sessions,
   logger, usage-collector, ai-client). REQUIRED follow-through in the same
   PR: repoint `scripts/gen-mcp-contract-fixtures.ts` (parses `src/index.ts`
   today) at `macos/EngramMCP/Core/MCPToolRegistry.swift` so the CI-gated
   `tests/fixtures/mcp-golden/tools.json` Swift parity test keeps working;
   trim `bootstrap.ts` (`createMCPDeps`/`createDaemonDeps`), `knip.json`
   entry points, `package.json` `dev` script, `src/cli` dispatch fallback,
   README HTTP/API section.
3. **DONE in PR #105 — DELETE corpus rule mining (get_rules + background miner + schema).**
   Remove `mineCorpusRulesOnce`/`mineRulesWithLLM`/`corpusMiningCandidates`/
   `writeMinedRules` + 2 scheduling call sites in
   `EngramServiceRunner.swift` (~:799-1113); `get_rules` def/dispatch in
   `MCPToolRegistry.swift`; `getRules`/`minedRuleRows` in `MCPDatabase.swift`
   and the get_context rule-folding branch (~:860-873, covered by
   `testGetContextIncludesMinedRulesForProject`); `ensureMinedRulesTables` in
   `EngramMigrations.swift` (~:586-608, 2 idempotent call sites, no FKs).
   Update tests in EngramServiceIPCTests/EngramMCPExecutableTests/
   MigrationRunnerTests. Existing `mined_rules` rows on installed DBs stay
   inert. Add get_rules removal note to `docs/mcp-tools.md` (it was never
   documented there — that omission was part of the cut rationale).
4. **DONE in PR #106 — DELETE Skills + Hooks config-browser pages.** Remove
   `Views/Pages/SkillsView.swift` + `HooksView.swift` (92 LOC each), the two
   `Screen` enum cases + switch arms + `Section.config` entries,
   MainWindowView dispatch arms, `skills()`/`hooks()` across
   protocol/client/mock/`FileSystemEngramServiceReadProvider` (+3 private
   parsing helpers used only here) + `EngramServiceSkillInfo`/`HookInfo`
   DTOs, and tests (HooksSkillsTests, EngramServiceClientTests parts,
   EngramUITests Skills/Hooks screens+tests). Repoint ServiceTelemetryTests'
   one `hooks` example command to another empty-provider command (e.g.
   `sources`). CONFIG sidebar shrinks 4→2 (Agents, Memory) — relabel if it
   reads oddly.
5. **DONE in PR #107 — DELETE lint_config MCP tool (Swift product side only).** Remove
   `lintConfig`/`lintIssues` + the 8 lint-only private helpers from
   `MCPFileTools.swift` (KEEP `projectReview` helpers and shared
   `trimTrailingSlash`); registry def/dispatch/category in
   `MCPToolRegistry.swift` (~:371, :909-910, :1138); the golden test +
   fixture in EngramMCPExecutableTests; doc rows `docs/mcp-tools.md:297`,
   `README.md:237`, `macos/EngramMCP/AGENTS.md:13`. LEAVE
   `src/tools/lint_config.ts` alone (reference-only). Evidence: 0 calls in
   ~995K tracked tool-call telemetry.
6. **DONE in PR #108 — DELETE dead peer-sync settings surface.** Remove the "Sync" GroupBox in
   `NetworkSettingsSection.swift:25` (it literally states "Sync is not
   implemented in the Swift service") and demote the README peer-sync
   section (~README.md:321) to a one-line historical note. Keep
   `settings.json` legacy keys (`syncEnabled`/`syncPeers`/...) parse-tolerant
   — do not crash on their presence; grep `macos/` for sync DTO/field
   consumers to size the full removal before deleting beyond the UI.
7. **DONE in PR #109 — DELETE verified-dead scaffolding bundle.** Deleted
   `SQLiteVecSupport.swift`, `VectorRebuildPolicy.swift`, their self-only test,
   and the unused Swift Cascade gRPC live-sync client/discovery/proto bundle.
   Kept Antigravity legacy cache + CLI transcript parsing, Windsurf cache
   reading, TS reference/dev Cascade tooling, and active Swift semantic/hybrid
   retrieval. Added a deletion-guard scan test, updated active docs, and moved
   Windsurf SourceCatalog to the actual cache root `~/.engram/cache/windsurf`.
8. **DONE in PR #110 — FOLD Favorites page into a Sessions FilterPill.** Delete the 63-LOC
   Favorites page clone + its Screen case; add a "Starred" FilterPill on
   SessionsPageView. KEEP star toggle, favorites table, `setFavorite` IPC,
   and `listFavorites()` (2 callers — repoint to the pill's query path).
   Both verifiers passed this at confidence 5.
9. **DONE in PR #111 — DEMOTE project-migration batch/undo/history UI (no deletion).** In
   `Views/Pages/ProjectsView.swift` (~:87) move Select / Move Selected /
   Undo Recent Move / History behind an Advanced (or Developer Tools)
   affordance; keep single-project move and ALL project_* MCP tools intact.
   Motivation: local `migration_log` has exactly 2 rows, both
   `_engram_e2e_test_*` from 2026-04-20, and `BatchMoveSheet.swift:8`
   documents a dry_run-omission commit risk. `project_aliases` stays — it is
   load-bearing for list_sessions/search/get_context.
10. **DONE in PR #112 — DEFAULT-OFF archived sources: cline / iflow / lobsterai.** Keep parser
    code + fixtures; change defaults so these three are not scanned unless
    the user enables them (Workspace > Sources under an "Archived" group).
    Local evidence: 3/2/1 sessions, last activity 2026-02-27/2026-02-27/
    2026-03-08. Do NOT touch minimax (234 local sessions, active). Update
    the "17 sources" claims in README/CLAUDE.md to describe the
    active-vs-archived split.

Explicitly REJECTED (do not implement, recorded so nobody re-proposes them
blind): hiding the `live_sessions` MCP stub (deliberate honest-unavailable
contract with its own regression tests; hiding creates a worse inconsistent
state), cutting Windsurf/Antigravity adapters (Antigravity is live),
cutting the Observability suite (deliberate 2026-06-15 rebuild; UI-only cut
strands live telemetry), cutting the whole semantic/vector bundle (hybrid
retrieval behind get_memory is live and tested — only item 7a is dead), and
demoting the Popover usage section (active UX work stream, owner decides
there, not a maintenance cut).

## Closed — perf-integration review findings (2026-07-04)

**Historical section (closed).** As of 2026-07-08 there were **no active**
items in this section. The CursorAdapter WAL-aware parse-cache signature and
the three P3 latent issues were closed in the Wave 5 perf-residual closeout;
older P1/Web UI entries remain below only as closeout evidence. Do not treat
the narrative below as open engineering work.

From the 18-agent adversarial review of the Codex-integrated 8-PR perf batch
(base `f9a236dc..main`). The one blocking item (fts_map self-heal ownership) was
already fixed on `main` (see `CHANGELOG.md`, new test
`FTSIncrementalTests.testReusedRowidWithUnchangedContentIsNotMaskedByStaleMap`).
Each item below was re-verified against real code and **later closed** (see
per-item Resolution notes). The narrative is retained as historical evidence
only; it is not an open fix-pass list.

### P1 — oversized-transcript (>10k msgs) silent truncation makes totals/tails stale

- **Where:** `JSONLAdapterSupport.windowedMessages` and CodexAdapter's own
  path (`macos/Shared/EngramCore/Adapters/Sources/CodexAdapter.swift:210`, and
  the `.messageLimitExceeded` return around `:98`–`:113`); consumers
  `macos/EngramMCP/Core/MCPTranscriptReader.swift` (`fullScanPage` `:347`,
  `collectVisiblePageWindow` `:384`). The former HTTP Web UI consumer was
  resolved by deletion in feature-cut item 1.
- **What changed:** an unwindowed read (`options.limit == nil`) that exceeds
  `ParserLimits.maxMessages` (10,000) no longer throws
  `.messageLimitExceeded`; it logs a private `.notice` and returns only the
  first 10k parsed records as success. This is a *deliberate, tested* change
  (AdapterWindowedReadTests) to avoid falling back to an uncapped legacy parser.
- **Why it was a problem (historical):** two downstream call sites still assumed
  "a whole read either fully succeeds or throws." MCP `get_session` computed
  `totalPages` from a truncated total, so a client that paged to the reported
  last page believed it read the whole session while the tail past record
  ~10,000 was silently missing; the resume primer's "last messages" could
  likewise go stale. Separately, `collectVisiblePageWindow` (cache-hit fast
  path) asked the adapter for `StreamMessagesOptions(offset: 0, limit: rawLimit)`,
  which bypassed the 10k cap that `fullScanPage` used to compute the cached
  total — so deep paging and the cached total disagreed about how much content
  existed.
- **Decision resolved (historical):** silent truncation was replaced by an
  explicit incompleteness signal. The preferred direction was adopted: a
  `truncated`/`totalKnownComplete` signal is threaded out of the adapter window
  so MCP totals and the resume primer report incompleteness instead of quietly
  capping (see residuals resolution below).

#### P1 residuals after Codex fix pass (re-verified 2026-07-05, Claude Code)

Codex's fix batches closed the *core* of P1: MCP `get_session` now surfaces
`truncatedAt` / `totalKnownComplete=false` and computes `totalPages` from the
capped window, `collectVisiblePageWindow` respects the cap via
`maxRawMessages`, the resume primer marks truncation, and markdown/JSON export
carry truncation metadata for the nine JSONL/cascade adapters that override
`streamMessagesWithMetadata`. Verified by re-reading the working tree plus green
focused suites (`AdapterWindowedReadTests`, `EngramMCPExecutableTests`,
`EngramServiceIPCTests`, `StartupBackfillTests`, `DatabaseManagerTests`). The
former HTTP Web UI suite and line anchors were resolved by feature-cut item 1
deletion. The two residuals below were resolved on 2026-07-05 by Codex:

- **Resolved by deletion:** the HTTP Web UI oversized-transcript
  banner/clamp path, helper-only tests, and `EngramWebUIServer` line anchors no
  longer exist after feature-cut item 1. MCP/export whole-transcript surfaces
  remain capped and marked; there is no browser transcript page left to track in
  this follow-up list.
- **Residual silent export truncation on adapters that do not override
  `streamMessagesWithMetadata`.** `KimiAdapter` (`:105`) and `OpenCodeAdapter`
  (`:220`) override only `streamMessages`, so they inherit the default
  `SessionAdapter.streamMessagesWithMetadata` (`SessionAdapter.swift:256`–`:264`)
  which always returns `truncatedAt = nil` / `totalKnownComplete = true`. An
  oversized (>10k message) session from either source therefore exports (and
  MCP-pages) capped at 10_000 with no truncation marker — the exact silent
  truncation P1 set out to remove, still present for these sources.
  **Resolution:** `KimiAdapter` and `OpenCodeAdapter` now override
  `streamMessagesWithMetadata` and report `truncatedAt = 10_000` /
  `totalKnownComplete = false` for whole-transcript reads that exceed the cap.
  Regression coverage lives in
  `EngramServiceIPCTests.testExportSessionMarksKimiOversizedTranscriptTruncated`
  and
  `EngramServiceIPCTests.testExportSessionMarksOpenCodeOversizedTranscriptTruncated`.

  **Validation:** focused
  `xcodebuild test -project Engram.xcodeproj -scheme EngramServiceCore
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` with the three
  new/changed `-only-testing` filters passed on 2026-07-05. The required
  `xcodebuild -project macos/Engram.xcodeproj -scheme Engram -configuration
  Debug build` also passed.

### P2 — Web UI session-page ETag omits DB-mutable display fields

- **Resolved by deletion:** feature-cut item 1 removed the HTTP Web UI session
  page and `EngramWebUIServer`, so this ETag path no longer exists.

### P2 — CursorAdapter parse cache keyed on shared WAL db mtime/size

- **Where:** `macos/Shared/EngramCore/Adapters/Sources/CursorAdapter.swift:126`
  (parse cache keyed via `ParsedTranscriptCache.Signature.forFile(dbPath)`).
- **Problem:** `state.vscdb` is Cursor/VSCode's live SQLite store, commonly in
  WAL mode; committed writes land in `-wal` and the main file's mtime/size can
  stay unchanged until a checkpoint. Long-lived adapter cache consumers can serve
  stale cached messages while Cursor is open.
- **Fix direction:** include the `-wal` (and `-shm`) sidecar mtime/size in the
  cache signature, or don't cache while the sidecar is non-empty.
- **Resolution (2026-07-08, Codex):** current Swift cache signatures include
  both `-wal` and `-shm` sidecar mtime/size, and the residual is covered by
  `AdapterWindowedReadTests.testParsedTranscriptSignatureIncludesSQLiteWalSidecars_repro`.

### P3 — lower-impact / latent

- **FTS `optimize` gate blind to full rebuilds.**
  `macos/EngramCoreWrite/Indexing/StartupBackfills.swift` `optimizeFts` (`:625`)
  gates the FTS5 `optimize` merge on `ftsContentSignature` (`:650`), computed
  from `sessions`/`insights` aggregates. A `FTSRebuildPolicy` full rebuild
  doesn't move those aggregates, so on a future `expectedVersion` bump the freshly
  rebuilt multi-segment index is never merged. *Latent* until the next tokenizer/
  schema version bump. Fix: also gate on a rebuild marker/version, not just the
  content signature.
  **Resolution (2026-07-08, Codex):** `FTSRebuildPolicy.finalizeRebuildIfReady`
  invalidates the stored optimize signature after swapping in the rebuilt table;
  coverage lives in
  `FTSRebuildPolicyTests.testFinalizeRebuildInvalidatesStoredOptimizeSignatureForSwappedTable_repro`.
- **Whitespace-only query returns empty vs old browse-all.**
  `macos/Engram/Core/Database.swift` `keywordSearchSQL` (`:418`), `ctes.isEmpty`
  branch (`:445`). When `CJKText.ftsMatchTerms` yields `[]` (e.g. a 3-space
  query), the new CTE returns no rows; the old correlated-EXISTS query returned
  the most recent non-hidden sessions. Fix: restore the empty-term browse-all
  fallback (or short-circuit whitespace-only queries upstream).
  **Resolution (2026-07-08, Codex):** the app read path now falls through to
  the empty-term browse-all branch and preserves hidden/skip/lite exclusions;
  coverage lives in
  `DatabaseManagerTests.testWhitespaceOnlySearchBrowsesRecentVisibleSessions_repro`.
- **`reconcileSkipTierIndexArtifacts` undercounts embeddings deletes.**
  `macos/EngramCoreWrite/Indexing/StartupBackfills.swift` (`:713`) discards the
  `session_embeddings` delete count, so the returned/logged `reconcile_skip_fts`
  total understates cleanup. *Latent* until sqlite-vec / `session_embeddings`
  is implemented. Fix: add the embeddings-delete row count to the return value.
  **Resolution (2026-07-08, Codex):** skip-tier reconciliation now includes
  `session_embeddings` deletions in its returned/logged total; coverage lives in
  `StartupBackfillTests.testReconcileSkipTierDeleteCountIncludesEmbeddings_repro`.

## Closed in cleanup

All follow-up items from the 2026-05-24 backlog cleanup pass have matching
implementation or verification coverage. Evidence is recorded in
`docs/backlog-cleanup-report.md`.
