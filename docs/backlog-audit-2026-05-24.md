# Backlog Audit - 2026-05-24

Scope: tracked repository files in `/Users/bing/-Code-/engram`.

Note: the user clarified that "read-only/no-write" excludes the audit document itself. This report is the only file written for this audit.

## Executive result

The current actionable backlog is small. The repo contains thousands of historical unchecked checklist lines, but they mostly live in old Swift migration plans and archived design docs. They should not be treated as active backlog unless reintroduced by the current canonical documents.

Most important current items:

1. Test target signing configuration still requires an explicit `DEVELOPMENT_TEAM=J25GS8J4XM` override.
2. `get_insights` still advertises actionable savings but returns a hardcoded "healthy" message.
3. `live_sessions` is still a documented MCP-mode stub.
4. Real usage probes remain net-new product work.
5. SST classifier/parent/tier single-source consolidation remains a structural follow-up.
6. Project move has a few remaining real-flow and edge-case verification gaps.
7. Some MCP semaphore/protocol TODO documentation is stale and should be cleaned up.

## Scan totals

| Item | Count |
|---|---:|
| Tracked files | 1006 |
| Non-archive keyword hit lines | 953 |
| Archive keyword hit lines | 73 |
| Non-archive unchecked checklist lines | 1519 |
| Archive unchecked checklist lines | 1694 |
| Deduplicated audit entries below | 41 |

Keyword families scanned included `TODO`, `FIXME`, `XXX`, `HACK`, `NOTE`, `Roadmap`, `Follow-up`, `Deferred`, `Backlog`, `Open questions`, `Known limitations`, `pending`, `待办`, `待定`, `后续`, `暂不实现`, `延后`, `延期`, `未完成`, and `未决`.

## Current entries

| Source | Excerpt | Blame time | Status | Basis |
|---|---|---:|---|---|
| `docs/roadmap.md:51` | `RepoDiscovery.discover` shells git inside the writer transaction | 2026-05-23T22:38:36+08:00 | Completed implicitly | Current `EngramServiceRunner` uses `sessionCwdCounts` -> `probeRepositories` -> `upsert`; `EngramServiceIPCTests` asserts it does not call `writer.write { RepoDiscovery.discover(db) }`. |
| `docs/roadmap.md:54` | Real usage probes | 2026-05-23T22:38:36+08:00 | Still valid | Service still injects `NoopStartupUsageCollector`; `usage_snapshots` has schema/tests but no real runtime collector wiring. |
| `docs/roadmap.md:56` | Signing config | 2026-05-23T22:38:36+08:00 | Still valid | `EngramTests` target has no pinned `DEVELOPMENT_TEAM`; app target has `J25GS8J4XM`. |
| `docs/mcp-swift.md:88` | `DispatchSemaphore` around the stdio loop | 2026-04-23T07:02:31+08:00 | Obsolete | Current `MCPStdioServer` has an async stdin loop. Remaining semaphores are in CLI, MessageParser, and RepoDiscovery, not MCP stdio dispatch. |
| `docs/reviews/2026-05-22-remediation-closeout.md:25` | SST full single-source consolidation | 2026-05-22T23:32:07+08:00 | Still valid | Deferred structural refactor, not part of the roadmap closeout. |
| `docs/reviews/2026-05-22-remediation-closeout.md:26` | service-side `.degraded` SLA | 2026-05-22T23:32:07+08:00 | Still valid | App surfaces indexing failure via events, but service `status` still lacks age-threshold SLA tracking. |
| `docs/reviews/2026-05-22-remediation-closeout.md:27` | Gemini cross-validation omissions | 2026-05-22T23:32:07+08:00 | Unknown | The source document marks it unverified; this audit did not run App Sandbox/App Nap/large JSON runtime probes. |
| `docs/reviews/2026-05-22-remediation-closeout.md:28` | semantic / embeddings / manual link-unlink / Windsurf+Antigravity ingest | 2026-05-22T23:32:07+08:00 | Still valid | False UI/claims were removed, but these remain unimplemented product features. |
| `docs/reviews/round7/advertised-vs-runtime.md:87` | `live_sessions` stub | 2026-05-22T22:01:19+08:00 | Still valid | `MCPToolRegistry` still returns `sessions: []` with "Live session monitor not available". |
| `docs/reviews/round7/advertised-vs-runtime.md:91` | `get_insights` partial stub | 2026-05-22T22:01:19+08:00 | Still valid | `MCPInsightsTool.swift:9-15` still hardcodes "No cost optimization suggestions". |
| `PROGRESS.md:182` | database is locked observation | 2026-04-22T15:09:33+08:00 | Obsolete | Old Phase A/B migration issue; current product uses Swift service/write gate. |
| `PROGRESS.md:183` | multiple MCP instances coexist | 2026-04-22T15:09:33+08:00 | Obsolete | The file itself says Phase B makes this no longer a problem; current MCP is a service client. |
| `PROGRESS.md:184` | advisory file lock for MCP write path | 2026-04-22T15:09:33+08:00 | Obsolete | Temporary Phase A/B idea superseded by service-side write serialization. |
| `tasks/review-shortcomings-todo.md:23` | `daemon.ts` / `index.ts` coverage | 2026-04-13T07:51:34+08:00 | Obsolete | Node runtime is no longer the shipped product runtime. This may matter only for dev/reference tooling. |
| `tasks/review-shortcomings-todo.md:35` | `biome.json`: enable `noExplicitAny: warn` | 2026-04-13T07:51:34+08:00 | Completed implicitly | `biome.json` already has `noExplicitAny: "warn"` with test-source override. |
| `tasks/review-shortcomings-todo.md:58` | `web.ts` too large | 2026-04-13T07:51:34+08:00 | Still valid | TypeScript web surface still exists; this is low-priority dev/reference structure debt. |
| `tasks/project-move-progress.md:98` | Round 5 review for Round 4 changes | 2026-04-20T22:13:41+08:00 | Obsolete | Multiple later reviews/remediations landed after Round 4; keeping this exact old review task active would duplicate later review work. |
| `tasks/project-move-progress.md:99` | UI manual Rename committed flow not verified | 2026-04-20T22:13:41+08:00 | Still valid | The document states it was not verified; this audit did not perform GUI/destructive real-flow validation. |
| `tasks/project-move-progress.md:100` | `recover fs_done` end-to-end test missing | 2026-04-20T22:13:41+08:00 | Still valid | Still a real E2E coverage gap unless a later dedicated test proves otherwise. |
| `tasks/project-move-progress.md:101` | Batch YAML not run on real large data | 2026-04-20T19:54:44+08:00 | Unknown | Requires real-data smoke verification; static audit cannot prove it. |
| `tasks/project-move-progress.md:102` | Archive heuristic lacks large boundary sample | 2026-04-20T22:13:41+08:00 | Still valid | Test sample breadth issue; no evidence found that a large boundary corpus was added. |
| `tasks/project-move-progress.md:103` | UndoSheet keyboard navigation / CAS mtime precision | 2026-04-20T22:13:41+08:00 | Still valid | Explicitly skipped due larger work; no completion evidence found. |
| `tasks/project-move-progress.md:104` | NFC/NFD fallback only handles `patchBuffer` | 2026-04-20T22:13:41+08:00 | Still valid | Still documented as known limitation; no evidence found that `findReferencingFiles` normalizes. |
| `tasks/issues.md:16` | Node indexer should always populate `file_path` | 2026-03-20T08:41:24+08:00 | Obsolete | File header says this is historical Node-era context; Swift has a workaround. |
| `tasks/issues.md:40` | No actual usage probes registered | 2026-03-20T04:14:52+08:00 | Still valid | Same active item as `docs/roadmap.md:54`. |
| `tasks/issues.md:44` | No RepoDetailView | 2026-03-20T04:14:52+08:00 | Completed implicitly | Current tree has `RepoDetailView.swift`; `ReposView` navigates into it. |
| `tasks/issues.md:49` | CLI resume missing | 2026-03-20T04:14:52+08:00 | Unknown | Historical Node-era spec gap; whether Swift CLI should implement it is a product decision. |
| `tasks/issues.md:53` | title regenerate endpoint is a stub | 2026-03-20T04:14:52+08:00 | Completed implicitly | Current `EngramServiceCommandHandler.regenerateAllTitles` and IPC tests exist. |
| `tasks/issues.md:58` | expensive computed SwiftUI properties / ISO formatter | 2026-03-20T04:14:52+08:00 | Completed implicitly | `docs/roadmap.md` marks formatter fix done; current service has shared statics for key hot paths. |
| `src/core/project-move/git-dirty.ts:7` | smart stash path for whitespace-only / untracked-only dirt | 2026-04-20T14:23:40+08:00 | Still valid | Code TODO remains in TypeScript dev/reference project-move path. |
| `src/core/project-move/jsonl-patch.ts:146` | oversized JSONL streamed line-by-line later | 2026-04-20T14:23:40+08:00 | Still valid | Code still documents 128 MiB in-memory cap and future streaming work. |
| `src/web.ts:1463` | SSE endpoint deferred | 2026-03-21T03:45:40+08:00 | Still valid | TypeScript web path still has polling `/api/live`, no SSE endpoint. |
| `plans/mcp-swift-shim-plan.md:324` | hardcoded MCP protocol version | 2026-04-22T19:59:17+08:00 | Completed implicitly | Current `MCPStdioServer` supports/fail-closes protocol versions and tests unsupported input. |
| `plans/mcp-swift-shim-plan.md:325` | DispatchSemaphore stdio bridge | 2026-04-22T19:59:17+08:00 | Obsolete | Same as `docs/mcp-swift.md:88`: MCP stdio loop is no longer semaphore-bridged. |
| `docs/swift-single-stack/2026-04-24-review-feedback-v2-followup.md:179` | idempotent migrations | 2026-04-24T11:37:27+08:00 | Completed implicitly | `EngramMigrations` has v2 migration paths for the named tables. |
| `docs/swift-single-stack/2026-04-24-review-feedback-v2-followup.md:180` | confirm `insights.deleted_at` intent | 2026-04-24T11:37:27+08:00 | Unknown | Requires historical schema/design adjudication. |
| `docs/swift-single-stack/2026-04-24-review-feedback-v2-followup.md:181` | smoke test ProjectsView | 2026-04-24T11:37:27+08:00 | Unknown | Requires UI smoke/manual verification; not run in this static audit. |
| `docs/swift-single-stack/2026-04-24-review-feedback-v2-followup.md:182` | AdapterRegistry collect-to-array -> AsyncStream | 2026-04-24T11:37:27+08:00 | Completed implicitly | Current `SwiftIndexer.streamSnapshots` is `AsyncThrowingStream`; `indexAll` writes batches. |
| `docs/swift-single-stack/2026-04-24-review-feedback-v2-followup.md:183` | connect CI | 2026-04-24T11:37:27+08:00 | Completed implicitly | `.github/workflows/test.yml` has lint, knip, typecheck, coverage, Swift, and UI-test jobs. |
| `macos/Engram/Views/Settings/AISettingsSection.swift:13` | NOTE: advertised-but-inert removal | 2026-05-22T22:24:47+08:00 | Completed implicitly | This is an explanatory note for removed inert embedding controls, not pending work. |
| `src/core/db/maintenance.ts:901` | NOTE: deliberately do not clear orphan flags | 2026-04-20T14:23:40+08:00 | Not backlog | Design note explaining intentional behavior. |

## Historical plan residue

These are not active backlog by default. They are old plans/drafts/archive docs. Treat as reference material unless a current canonical document reopens a specific item.

| Area/file group | Count | Status |
|---|---:|---|
| `docs/superpowers/plans/2026-04-23-swift-single-stack-migration.md` unchecked checklist lines | 242 | Historical migration plan; current Swift product has moved beyond this checklist. |
| `docs/superpowers/plans/implementation/*stage*.md` unchecked checklist lines | 645 | Historical implementation plans. |
| `docs/superpowers/plans/drafts/*swift-single-stack*.md` unchecked checklist lines | 544 | Draft plans, not current backlog. |
| `plans/project-move-takeover.md` unchecked checklist lines | 29 | Historical takeover plan; Swift service project-move pipeline is current. |
| `docs/archive/**` unchecked checklist lines | 1694 | Archived material, obsolete unless promoted back into current docs. |
| `docs/archive/**` keyword hit lines | 73 | Archived deferred/TODO/backlog mentions. |

Notable archive examples:

| Source | Excerpt | Status |
|---|---|---|
| `docs/archive/superpowers/specs/2026-03-22-competitive-improvement-design.md:91` | Backlog design only | Archived design backlog |
| `docs/archive/superpowers/specs/2026-03-22-observability-design.md:22` | External log aggregation deferred | Archived product idea |
| `docs/archive/superpowers/specs/2026-03-22-observability-design.md:23` | User-facing log export/upload deferred | Archived product idea |
| `docs/archive/superpowers/specs/2026-03-22-observability-design.md:24` | OpenTelemetry SDK integration deferred | Archived product idea |
| `docs/archive/superpowers/specs/2026-04-06-ai-audit-log-design.md:474` | macOS app UI page later | Archived product idea |
| `docs/archive/superpowers/specs/2026-04-06-ai-audit-log-design.md:476` | Token cost calculation later | Archived product idea |

## Statistics

Status distribution across the deduplicated audit entries:

| Status | Count |
|---|---:|
| Still valid | 16 |
| Completed implicitly | 8 |
| Obsolete | 8 |
| Unknown | 5 |
| Not backlog | 1 |
| Historical plan residue groups | 4 |
| Total | 42 |

Directory/module distribution:

| Directory/module | Entries |
|---|---:|
| `docs/roadmap.md` and current docs | 11 |
| `docs/reviews/**` | 6 |
| `tasks/**` | 15 |
| `src/**` TypeScript dev/reference | 4 |
| `plans/**` | 2 |
| `docs/swift-single-stack/**` | 5 |
| Historical checklist groups | 4 |

## Priority recommendations

1. Fix test target signing configuration so app-hosted tests work without command-line `DEVELOPMENT_TEAM` overrides.
2. Either implement real `get_insights` suggestions or change the tool description/output to avoid promising savings estimates.
3. Either implement real `live_sessions` or document the MCP-mode limitation in the tool description.
4. Keep real usage probes as explicit product-scope work, not a bug-fix residue.
5. Do SST single-source consolidation in a dedicated PR if adapter/tier/parent drift continues to be costly.
6. Add/perform the project-move real-flow validations: Rename committed flow, `recover fs_done` E2E, archive heuristic larger corpus.
7. Clean stale MCP semaphore/protocol TODO docs so future audits do not rediscover already-closed risk.
8. Decide whether old TypeScript dev/reference TODOs are worth tracking, or move them to an explicit "reference tooling debt" section.

## Checks run

- `git status --short --branch`
- `git ls-files`
- `git grep` keyword scan across tracked files, excluding `macos/build` and `node_modules`
- `git grep` filename scan for `todo`, `roadmap`, `followup`, `backlog`, `plan`, and `issue`
- `git grep` unchecked checklist scan
- `git blame -L` for deduplicated current entries
- Targeted source reads for `MCPStdioServer`, `MCPToolRegistry`, `MCPInsightsTool`, `EngramServiceRunner`, `RepoDiscovery`, `SwiftIndexer`, `project.yml`, generated pbxproj, CI workflow, and key TS TODO sites

## Checks not run

- No tests were run; this was a static backlog audit.
- No UI smoke/manual destructive workflow was run.
- No App Sandbox/App Nap/large-transcript runtime probes were run.

## Evidence notes

- Worktree was clean before report creation: `## main...origin/main`.
- This report is the only intended write from the audit.
