# Restore legacy Web capabilities on the native backend

Owner goal: compare with the previous version and complete the full upgraded
native backend iteration. Legacy reference: `5013bab7:src/web.ts`,
`src/web/views.ts`, and `src/web/routes/`. Current implementation belongs to
`.worktrees/collector-server-web-20260905` on `codex/collector-server-web-20260905`.
The existing Swift Service, RemoteServer, read client, and read repositories
remain the runtime. Reuse the old information architecture and interactions;
do not replace working backend code or reintroduce a Node product process.

## Capability coverage

| Legacy capability | Native target / verification | Current state |
| --- | --- | --- |
| Sessions / Search / Stats / Health / Settings navigation | Working pages and browser back/navigation | All five pages implemented locally; fixture navigation/rendering checked; Settings backend passes focused 3 service / combined 91 remote tests; actual-package E2E pending |
| Source and project multi-select; searchable project picker | Typed filters, paged visible facets, real filtered results | Plural filters and facets locally verified (93 service / 83 remote tests); picker UI tested; real HTTP/IPC E2E pending |
| Agent hide/all/only | Preserve hidden/privacy/skip rules; never upgrade child tiers | Local producer/client/UI tests pass; permitted agent detail/transcript regression fixed; full HTTP/IPC E2E pending |
| Native or stored session ID jump | Exact identity query, canonical detail, ambiguity choice | Local UI/producer/HTTP/client tests pass; deployed acceptance pending |
| Relative dates, message counts, paging | Scalar metadata from Service; complete paged navigation | Previous/Next and range/optional-total display implemented; D1 snapshot/read-budget regressions fixed with 80 producer / 92 remote tests passing; exact total cached on the held snapshot; actual-package acceptance pending |
| Complete transcript, Markdown, code copy, tool/system fold | Existing frame/hash/continuation contract and browser rendering | Existing implementation; retain during parity changes |
| Stats by source/project/day/week and noise filter | Authorized server-side aggregates; group totals and pagination | Local implementation passes 76 service / 87 remote tests; UI part of 89 passing JS tests; fixture rendering checked; actual-package E2E pending |
| Health and per-source status/history | Current capture/ingest/FTS/replica observations; no false HQ-local source-path checks | Health UI consumes overview; fixture rendering checked; history and currently unreported signals remain pending |
| Settings / database / sources / peers / project aliases display | Explicit safe fields from current native state; no secrets | Four legacy sections, paged aliases and path-alias regression locally verified (3 service / 91 remote); live package acceptance pending |
| Search modes/status/tools/date filters | Native capability-aware typed search; retain unavailable-mode semantics | D1 date/tool/`totalCount` producer 80/80 after snapshot-total cache; D2 UI 99/99 and desktop/mobile fixture rendering pass; native scoped search plus full producer/unscoped integrity suites 97/97 and HTTP/client/UI 58/58 pass; full typed metadata-client suite 41/41 passes; actual-package acceptance pending; D11 insight search/full-content checks are tracked below |
| Children / timeline | Existing native relationships and authoritative visible metadata | D6 locally verified: confirmed/suggested child paging and generation-bound normalized timeline; 120 UI, 26 service/real-composition and 45 remote/auth/client tests pass; desktop/mobile fixture rendering checked; installed-package acceptance pending |
| Costs, per-session costs, usage, file/tool analytics, repositories | Existing native read repos with typed bounded responses | D3 Costs UI 103 JS checks and desktop/mobile fixture checks pass; native costs producer 4/4 and remote/client/UI/auth 111/111 pass. D8 tool analytics locally passes 132 UI / 4 producer / 100 remote checks; D8/D9 Files/Usage/Repositories locally pass 142 UI / 15 native+composition / 106 remote checks; actual-package acceptance remains pending |
| AI audit and stats | Safe native read projection and actual native call recording | D10 locally verified: chat and embedding recording, three typed reads, 149 UI / 47 native+composition+regression / 110 remote checks. Optional stored-body viewing and installed-package acceptance remain pending |
| Project migration/CWD and sync status/session reads | Current native read equivalents; explain retired fields | Migration/CWD: D15 (below). Sync: the Node peer-sync model is retired; Health already shows per-source heartbeat, last capture and replica acknowledgements from the capture pipeline, and the Settings Sync section now says so and links to Health (UI test in `collector-web-ui.test.ts`) |
| Legacy local probes: sources/skills/memory/hooks/hygiene/live/alerts | Map actual retained native capability and intended consumer; do not silently omit or simulate remote-local filesystem access | Explicitly mapped 2026-09-13: Settings renders a "Not available in this deployment" section naming skills/hooks/memory/hygiene, live events/monitor alerts, resume/link-sessions and dev utilities as intentionally absent because the Web runs on HQ and reads captured sessions only. Sources are covered by Source settings. No remote-local filesystem access is simulated |
| Configuration, alias and project writes, sync triggers, AI generation, resume/link operations | Owner explicitly included legacy Web writes on 2026-09-13. Route through existing Swift service write gate; add explicit Web write authorization and old-flow acceptance coverage | Authorized; 23 non-GET declarations inventoried. Editor credential/session authority passes native tests; Auth status GET passes 24 tests; alias editor UI passes 110 script tests and fixture add/delete rendering. D4 exact-pair alias write contract accepted and implementation dispatched. Native alias writes and actual HTTP/IPC/SQLite composition pass 8/8; remote/auth/UI/client regressions pass 84/84. D5 source configuration delivered locally: 114 script tests, 7 service/real-composition and 56 remote/auth/UI/client tests pass; other mutations remain pending |
| Developer-only mock/log/lint mutation APIs | Inventory separately from user-facing product parity | Not started; no implicit Web exposure |

## Source configuration — locally verified

D5 locally verified after D4 closure: 114 shipped-script, 7 service/composition,
and 56 remote/auth/UI/client checks pass; desktop/mobile fixture flow checked.
Installed-package acceptance is pending. GET
`/web/api/settings/sources` / `webSourceSettings` returns sorted
`{sources:[{key,label,enabled}]}` for every native source. POST on the same path
/ capability-protected `webSetSourceEnabled` accepts `{source,enabled}` and
returns that pair from fresh state. Parent delivered UI and real composition; Cursor delivered typed backend
and focused native tests. Both endpoints reject unknown fields and source IDs;
POST requires editor authority.

Reuse `setSourceEnabled` and its recovery-aware settings/visibility update.
`ServiceCaptureIngestRuntime.policy(at:)` reads the same `disabledSources`
state afresh for intake and metadata. Offer current enabled/disabled source
states independently of the paged Settings metadata response: all sources
being disabled must not remove the controls needed to re-enable them. The UI
must describe HQ ingest/visibility, not promise control of remote collectors.
Use the existing editor cookie and typed write path; validate known source IDs.
Verify disable/re-enable, preservation of manual hide and unrelated settings,
and recovery when all sources are off. No arbitrary JSON configuration editor
or retired Node peer settings is required to deliver these controls.

## Children and timeline — locally verified

D6 passed 120 UI, 26 service/composition and 45 remote/auth/client tests.
Desktop/mobile fixture rendering was inspected; installed-package acceptance
remains pending. Children reads use
`/web/api/sessions/:id/children` / `webChildren` with B2 snapshot/cursor and
`{sessionId,snapshotId,observedAt,items:[{relationship,session}],nextCursor?}`.
Both confirmed and suggested children remain reachable; every parent/child is
admitted through current capture policy and visibility, and skip stays excluded.
Timeline reads use `/web/api/sessions/:id/timeline` / `webTimeline` with required
`generation`, offset and limit. Response contains original ordinals, redacted
100-character previews, roles/types, optional timestamps/tool/tokens/gaps,
actual totalEntries and nextOffset. Reuse normalized transcript admission and
bounded windows; do not reopen original source paths on HQ or fake metadata
from FTS. Parent owns UI/composition; Cursor owns backend/focused tests.

## Relationship writes — locally verified

D7 is assigned through Herdr to the existing Cursor pane, backend/tests only.
Restore POST/DELETE `/web/api/sessions/:id/link`, POST
`/web/api/sessions/:id/confirm-suggestion`, and DELETE
`/web/api/sessions/:id/suggestion`. Link accepts `parentId`; suggestion actions
accept the expected `suggestedParentId` to reject stale UI actions. Reuse native
relationship owners through the service gate; retain cycle validation, skip
policy and sticky dismissal. Web authorizes current child and affected parents,
requires editor/CSRF/local capability, and returns explicit stale conflicts.
Parent delivered detail UI (128 script checks), HTTP/client verification (47 checks), and real composition assertions. Cursor delivered native service helpers/tests; all 21 service/native-regression/composition checks pass in `relationships-d7-service3.log`. No deployment is included.

## Current analytics batch

D8 tool analytics is locally verified: 132 UI, four native producer and 100
remote/auth/client/UI checks, plus captured-tool HTTP/IPC composition. D8 file
activity now has typed `/web/api/file-activity` / `webFileActivity`, current
capture admission, full file/operation totals and per-path action counts. Exact
path keys stay distinct; redacted component breadcrumbs omit host roots. The
producer passes 5/5. New ingest and finite historical repair passed 9/9 in the
previous batch; disabled sources/corrupt heads retry on a later process start.

D9 adds `/web/api/usage` / `webUsage`: latest per source+metric, deterministic
timestamp tie handling, current enabled-source scope, and explicit basis for
indexed-session estimates. Usage producer passes 2/2; real native collection
from captured tokens and HTTP/IPC consumption passes in the composition test.
GET only reloads recorded observations. Repository `/web/api/repos` / `webRepos`
uses stored `git_repos` and `git_repo_cwd_aliases`, explicit `serverFilesystem`
scope, fresh visible captured-session counts and complete snapshot paging.
Repository producer passes 7/7; final native/composition batch passes 15/15 in
`analytics-d9-service3.log`, combined remote checks 106/106 in
`repos-d9-web-remote4.log`. The composition uses two distinct human instructions
to satisfy existing native repository-discovery visibility.

Parent delivered Files/Usage/Repositories UI (142 script tests, responsive
cards, desktop/mobile render checks). Cursor delivered repository backend validation;
parent verified final composition. The composition injects a repository probe and
verifies the real native writer/HTTP path; production Git and collector-machine
telemetry are not covered by it. No installed-package acceptance or deployment
has occurred. Full legacy read/write scope remains active. D10 AI audit/stats is assigned through Herdr to Cursor (native recording/read
backend); parent owns UI/composition. Next: insight search, then remaining migration/sync/probes/writes.

## AI audit and statistics — locally verified

D10 delivers call-history filters, held paging, safe detail fields, resolved
statistics intervals, totals and caller/model/hour groups. Parent UI passes
149 script checks and desktop/mobile render checks. Herdr Cursor delivered
chat audit writes and three typed read routes; parent added real chat -> writer
-> HTTP/IPC composition and fixed fractional-second query bounds that excluded
fresh records. The 23 chat/producer/composition checks pass in
`ai-audit-d10-service5.log`. Its one failed embedding fixture has been fixed;
all six embedding tests plus 18 existing guardrail/readiness tests pass in
`ai-audit-d10-service6.log`. Remote auth/HTTP/client/UI checks pass 110/110 in
`ai-audit-d10-web-remote3.log`.

Parent implemented embedding observations per actual HTTP attempt, recording
through the same native gate from service search and both background backfills.
Compatibility retries are distinct calls; empty input/open circuit are not.
No test sends an external provider request. Bodies remain disabled by default,
with optional redacted persistence and Web presence flags. Optional body viewing
is still a full-goal follow-up. No installed-package acceptance or deployment.

## Insight search and full content — locally verified

D11 is assigned through Herdr to Cursor (native search/read backend); parent
owns UI/composition. Restore legacy `src/tools/search.ts` vector top-five
insights and FTS fallback, separate from session filters. Extend Web search with
`insightResults` previews and provide bounded, revision-bound Unicode-scalar
continuation for full insight content. Reuse native vector math, current query
embedding and persisted insight vectors; no second provider query for insights.
Exclude superseded records and source-linked notes whose session is not
currently admitted; unlinked insights are global notes. Preserve existing
session keyword/semantic/hybrid behavior and source policy. Verify insight-only
matches, Unicode continuation, stale/revoked content and typed HTTP/auth/client
flows. Parent UI passes 154 script checks and desktop/mobile fixture rendering.
The reader preserves Unicode scalar continuation and rejects changed revisions;
logout, navigation and close invalidate in-flight content. Native D11 passes
17 service/composition checks (`ai-audit-d11-service5.log`), 11 semantic integrity
checks (`ai-audit-d11-semantic-integrity2.log`), and 30 remote HTTP/base-client
checks (`ai-audit-d11-web-remote2.log`). Insight-only semantic corpus and
restrictive session filters are fixed, with one reused embedding request.
The newly extended `WebMetadataClientTests/testSearchAndStatusRoundTripTypedCommands_repro`
was independently run and passed in `ai-audit-d11-web-metadata.log` (one check).
D11 totals are 28 native/composition/regression and 31 HTTP/client checks.
Installed-package acceptance remains pending.

## Insight saving — locally verified

D12 restores legacy supplied-text saving, not AI generation:
`5013bab7:src/web.ts:665` delegates to `handleSaveInsight`.
Cursor owns typed POST `/web/api/insights`, editor/Origin/CSRF/capability checks,
current source-session admission and native gate/FTS/dedup reuse. Never let a
Web save supersede a hidden or otherwise unadmitted source-linked note.
Parent owns the existing Search-page composer and HTTP/IPC composition.
The UI passes 160 script checks; desktop/mobile fixture save and full-reader
flows were inspected. Actual long-note save -> SQLite -> FTS search -> reader
assertions pass in `CollectorWebDemoTests/testAliasEditorThroughHTTPAndServiceIPC`
(`ai-audit-d12-service1.log`). All five focused writer tests pass in service2,
and four HTTP/six write-client checks pass in remote1. D12 totals: six native /
ten remote checks. Installed-package acceptance remains pending.

## Summary and title generation — locally verified

D13 is assigned through Herdr to Cursor for backend/focused tests. Restore
POST `/web/api/sessions/:id/summary` and `/title` with `{generation}` and
`{sessionId,generation,summary? or title?,displayTitle?}` responses. Preserve
custom-name display priority and add the full saved summary to session detail.
POST `/web/api/titles/regenerate` starts only missing-title eligible sessions
(maximum 500), returning `started`/`running` and optional total. Reuse native AI
client, audit and batch coordinator; current source/generation admission must
hold before provider work and inside persistence. No missing-provider metadata
fallback may masquerade as generated AI content. Preserve native non-Web batch
behavior. Fix generated-summary persistence without changing the shared
200-character preview helper globally; reject oversize output explicitly.

Parent UI passes 167 script checks and desktop/mobile fixture rendering for all
three actions. Full-summary reopening and custom-name precedence are covered.
Ten focused service tests, five HTTP tests and the actual full-summary
`CollectorWebDemoTests/testSyntheticCaptureToCentralToWeb` composition pass in
`ai-audit-d13-service2.log`, `ai-audit-d13-web-remote.log` and
`ai-audit-d13-demo.log`. The older native configured-AI generateSummary branch
now reuses full-summary persistence. Three native checks (complete persistence,
no-provider fallback and admission-before-settings lookup) pass in
`native-summary-and-config-final.log`. The generation write-client test passes
in `ai-audit-d14-web-remote2.log`. D13 totals are fourteen native/composition
and six HTTP/client checks; installed-package acceptance remains pending.
No live AI calls or deployment are included. All other legacy reads and
approved writes remain in scope.

## AI configuration — locally verified

D14 GET/POST `/web/api/settings/ai` is assigned through Herdr to Cursor for
backend/tests; parent owns UI and real composition. GET returns
`{settings:{...}}` for explicit native summary/title/embedding fields and
`aiAudit`. POST accepts a nonempty patch of those fields and returns the same
projection. Reuse `SecureSettingsFileWriter.mutateJSON` inside the service gate;
keep unrelated keys, reject arbitrary/secret keys, validate scalar types and
bounds, and retain editor/Origin/CSRF/local capability checks. GET must not read
Keychain, migrate secrets or call providers. Credentials retain the existing
native secure owner. Environment overrides can take precedence; changing
embedding parameters does not rebuild stored vectors.

Parent UI passes 173 script checks and desktop/mobile fixture save/reload
inspection. It sends only edited values and clears private drafts on logout.
Eight writer tests pass in `ai-audit-d14-service4.log`; fourteen remote
HTTP/client/allowlist checks pass in `ai-audit-d14-web-remote2.log`. The actual
HTTP/IPC/settings-file composition passes in `ai-audit-d14-demo.log`, with the
extended summary/title/audit resolver assertions also passing in
`native-summary-and-config-final.log`. D14 totals are nine native/composition
and fourteen remote checks. Multiline prompts/styles and native shared-provider
embedding URL precedence are preserved; unsafe stored URLs are never echoed.
No installed-package acceptance or deployment yet.

## Project migration APIs — accepted (2026-09-13)

D15 is implemented and accepted: 21 service tests
(`output/web-parity-20260913/d15-service-core.log`) and 5 remote-server tests
(`d15-remote-server-core.log`) pass, and the routes ship in the HQ packages
listed under "HQ deployment and residual risk" below. The paragraphs that
follow are the contract the implementation was verified against.

D15 implementation was assigned through Herdr to Cursor after the read-only
owner/fixture assessment. Preserve the full existing move/archive/undo/batch
behavior; no replacement migration UI is needed by the baseline Web views.
GET `/web/api/projects/cwds?projectKey=` is captured metadata with published
project identity, complete bounded paging, safe location labels/keys and current
capture/source/hidden/skip admission. Never treat a captured path or machine ID
as server directory ownership or implicitly feed it into a move request.

GET `/web/api/migrations?state&limit` is server-filesystem operation history,
requiring editor authority and local capability even though it is a GET.
POST `/web/api/projects/{move,archive,undo,move-batch}` and
`/web/api/projects/move-batch/cancel` require editor/Origin/CSRF/capability and
explicit server paths. Reuse native confinement, pipeline, review/manifest,
undo and registry behavior. Web operation IDs are required UUIDs and are
internally namespaced `web-project:` for replay/cancellation isolation.
Keep native JSON batch documents and bounds; do not add a YAML dependency or
generic command proxy. Share only the necessary project DTO definitions if the
RemoteServer target requires them; do not import the broad native client.

Cursor owns backend and focused native/HTTP tests. The native lane is released
for D15 after `native-summary-and-config-final.log` passed four checks. For real
fixture moves, make the confinement home honor `CFFIXED_USER_HOME` only in an
identified XCTest process, keeping production behavior unchanged and avoiding
HOME mutation or real user-source probes. Verify current metadata admission,
editor-only history, denied writes, real preview/move/undo, bounded batch and
registry replay/cancel behavior. Parent owns docs and review; no production
moves, transfer, deployment or service restart is authorized by these tests.

## Next native migration and sync mapping

The baseline `5013bab7:src/web/views.ts` has no references to the migration,
CWD, handoff, resume, session-link or sync-trigger endpoints. The migration
APIs live in `src/web/routes/project-migrations.ts`; do not invent a replacement
migration UI merely to mirror those APIs. Preserve the full operation scope
and provide the native Web adapter where required, with the existing macOS
operation flow as the reference consumer.

Current native owners are `EngramServiceCommandHandler+ProjectMigration.swift`
(`projectMove`, `projectArchive`, `projectUndo`, `projectMoveBatch`) and
`SQLiteEngramServiceReadProvider.projectMigrations/projectCwds`. Keep the real
preview, operation-ID replay/cancellation and writer-gate ownership. Current
`validateProjectPathConfined` restricts server operations to non-sensitive
paths beneath its home; a captured CWD or machine ID is not evidence that a
remote collector's directory belongs to that server. Explicitly distinguish
source metadata from operations on the server filesystem. Native unscoped
migration/CWD reads are not automatically suitable Web projections.

For sync, reuse `remoteSyncStatus`, `remoteProjectSyncPreview`,
`remotePushProject` and `remotePullProject` in
`EngramServiceCommandHandler+RemoteSync.swift`, backed by
`RemoteSyncCoordinator`. `triggerSync` remains a stub and is not a completion
path. Current status counts are unscoped; Web must retain its current source
and visibility policy. Verify adapters with temporary-project and synthetic
archive fixtures, never with production moves or transfers. These mappings
identify owners and constraints; migration/sync Web parity is not completed.

## Explicit legacy GET inventory

Source verification on 2026-09-13 found 40 literal `app.get` declarations in
`5013bab7:src/web.ts` and its seven route modules: seven HTML/navigation routes
and the 33 API routes below. This is a capability inventory, not a promise to
retain Node entrypoints or every old URL. A native equivalent needs actual
behavior evidence before its capability is closed. Non-GET mutation scope is
tracked separately above.

| Legacy API | Source at `5013bab7` | Native/Web coverage |
| --- | --- | --- |
| `/api/status` | `src/web.ts:546` | `/web/api/overview`; partial status projection |
| `/api/health/sources` | `src/web.ts:988` | Overview / Health page; source history and missing signals pending |
| `/api/sources` | `src/web.ts:993` | Settings enabled-source projection; remaining source details pending |
| `/api/skills` | `src/web.ts:1007` | Local-machine probe; explicitly listed as unavailable in Settings ("Not available in this deployment"). Use the Engram app on that Mac |
| `/api/memory` | `src/web.ts:1076` | Native memoryFiles reader reads the HQ home, not a collector's; explicitly listed as unavailable in Settings |
| `/api/hooks` | `src/web.ts:1119` | Local-machine probe; explicitly listed as unavailable in Settings |
| `/api/hygiene` | `src/web.ts:1157` | Local-machine probe; explicitly listed as unavailable in Settings |
| `/api/live` | `src/web.ts:1275` | Native liveSessions reads local source files, which HQ does not own; Health shows per-source last capture/heartbeat instead; explicitly listed in Settings |
| `/api/live/events` | `src/web.ts:1279` | Explicitly listed as unavailable in Settings; Health observations replace the local event stream |
| `/api/monitor/alerts` | `src/web.ts:1291` | No native alert store exists; explicitly listed as unavailable in Settings; Health "needs attention" notes cover retryable/quarantined captures |
| `/api/ai/audit` | `src/web/routes/ai-audit.ts:30` | D10 native recording and typed `/web/api/ai/audit` read locally verified; optional body viewing pending |
| `/api/ai/audit/:id` | `src/web/routes/ai-audit.ts:57` | D10 native recording and typed `/web/api/ai/audit/:id` read locally verified; optional body viewing pending |
| `/api/ai/stats` | `src/web/routes/ai-audit.ts:66` | D10 native recording and typed `/web/api/ai/stats` read locally verified; optional body viewing pending |
| `/api/project-aliases` | `src/web/routes/project-aliases.ts:16` | `/web/api/settings` aliases; local read tests pass |
| `/api/project/migrations` | `src/web/routes/project-migrations.ts:64` | Native projectMigrations reader exists; Web projection pending |
| `/api/project/cwds` | `src/web/routes/project-migrations.ts:100` | Native projectCwds reader exists; Web projection pending |
| `/api/search/status` | `src/web/routes/search.ts:56` | D2 `/web/api/search/status`; authorized eligible/embedded counts + progress; `insightResults` not on this surface |
| `/api/search` | `src/web/routes/search.ts:72` | D2 `/web/api/search` keyword/semantic/hybrid via scoped native provider; D11 insightResults and full reader locally verified (28 native / 31 remote checks) |
| `/api/search/semantic` | `src/web/routes/search.ts:113` | Not a separate native 501 route; use `/web/api/search?mode=semantic` + Service degrade |
| `/api/sessions` | `src/web/routes/sessions.ts:110` | `/web/api/sessions`; D1 snapshot total cached on lease; producer 80/80 |
| `/api/sessions/:id` | `src/web/routes/sessions.ts:139` | `/web/api/sessions/:id`; implemented, actual-package acceptance pending |
| `/api/sessions/:id/messages` | `src/web/routes/sessions.ts:147` | `/web/api/sessions/:id/messages`; implemented, actual-package acceptance pending |
| `/api/sessions/:id/children` | `src/web/routes/sessions.ts:213` | D6 `/web/api/sessions/:id/children`; confirmed/suggested paging locally verified |
| `/api/sessions/:id/timeline` | `src/web/routes/sessions.ts:231` | D6 `/web/api/sessions/:id/timeline`; generation-bound normalized window locally verified |
| `/api/stats` | `src/web/routes/stats.ts:30` | `/web/api/stats`; local component tests pass |
| `/api/costs` | `src/web/routes/stats.ts:45` | `/web/api/costs`; paged full-set aggregates, raw USD; D3 local producer 4/4 and combined remote 111/111 |
| `/api/costs/sessions` | `src/web/routes/stats.ts:53` | `/web/api/costs/sessions`; authorized top 20/100, linked detail UI; D3 local checks pass; actual-package acceptance pending |
| `/api/file-activity` | `src/web/routes/stats.ts:73` | D8 typed file/action totals, filters and paging locally verified |
| `/api/tool-analytics` | `src/web/routes/stats.ts:90` | D8 typed tool/session/project aggregates locally verified |
| `/api/usage` | `src/web/routes/stats.ts:98` | D9 latest recorded metrics and native estimate basis locally verified |
| `/api/repos` | `src/web/routes/stats.ts:103` | D9 stored server probes and current session associations locally verified |
| `/api/sync/status` | `src/web/routes/sync.ts:30` | Node peer sync is retired. Capture replication status is the Health page per-source heartbeat, last capture and replica acknowledgements; Settings Sync explains this and links to Health (UI test) |
| `/api/sync/sessions` | `src/web/routes/sync.ts:38` | Per-session peer-sync rows have no native equivalent; replica acknowledgements are per source on Health. Explicitly explained in Settings Sync |

## Explicit legacy non-GET inventory and approved writes

Source verification on 2026-09-13 found 23 literal POST/DELETE declarations
at `5013bab7` in the same Web entrypoint and route modules. This includes
POST-shaped reads and developer utilities; HTTP method alone does not imply a
product database mutation. The owner explicitly included legacy writes plus
configuration editing. No production data mutation is part of implementing or
fixture-testing these features.

| Legacy surface | Existing native reuse / required work | State |
| --- | --- | --- |
| POST `/api/summary`, `/api/insight`, `/api/session/:id/generate-title`, `/api/titles/regenerate-all` (`src/web.ts:600,665,788,819`) | Service `generateSummary`, `saveInsight`, `generateProjectWorkTitles`, `regenerateAllTitles`; `5013bab7:src/web.ts:665` confirms `/api/insight` saves supplied text via `handleSaveInsight`; it does not generate AI content. Summary and titles retain their separate generation behavior | D12 supplied-insight save locally verified (6 native / 10 remote); D13 summary/title generation locally verified (14 native / 6 remote) |
| POST `/api/handoff` (`src/web.ts:724`) | Existing `handoff` reader; POST-shaped read, no invented database write | Served by the native MCP `handoff` tool for agents; the baseline Web views had no handoff UI, so no Web projection is added. Not a product gap |
| POST `/api/link-sessions` (`src/web.ts:762`) | Service `linkSessions` operates local filesystem symlinks; collector/HQ location must be explicit | Explicitly unavailable from the HQ Web (Settings note): symlinks must be created on the machine that owns the session; use the Engram app there |
| POST/DELETE `/api/project-aliases` (`src/web/routes/project-aliases.ts:20,28`) | Service gate and alias schema are reusable; current `manageProjectAlias` normalizes basenames and rewrites all path-shaped aliases (handler:2358). Web must resolve the selected published pair and mutate that exact authorized pair without globally rewriting unrelated aliases | Approved; UI 110 tests and fixture flows pass; native writes and real HTTP/IPC/SQLite composition pass 8/8; remote/auth/UI/client regressions pass 84/84; installed-package acceptance pending |
| POST `/api/project/move`, `/undo`, `/archive`, `/move-batch` (`src/web/routes/project-migrations.ts:119,170,198,250`) | Service `projectMove`, `projectUndo`, `projectArchive`, `projectMoveBatch`; retain preview/result/undo semantics and operation ownership | Approved; Web adapter/UI pending |
| POST/DELETE `/api/sessions/:id/link`, POST `confirm-suggestion`, DELETE `suggestion` (`src/web/routes/sessions.ts:177,187,193,200`) | Service `setParentSession`, `clearParentSession`, `confirmSuggestion`, `dismissSuggestion`; preserve hidden/skip restrictions and stale-suggestion checks | D7 locally verified: 128 UI, 47 remote/auth/client and 21 service/native-regression/real-composition tests pass; installed-package acceptance pending |
| POST `/api/session/:id/resume` (`src/web/routes/sessions.ts:326`) | Native `resumeCommand` returns instructions; old launch action needs actual target-machine execution mapping | Explicitly unavailable from the HQ Web (Settings note): launching a CLI must happen on the owning machine. Showing a copyable resume command is an optional follow-up, not parity-blocking |
| POST `/api/sync/trigger` (`src/web/routes/sync.ts:65`) | Current handler `triggerSync` still returns an explicit not-implemented result (verified 2026-09-13); adapt actual capture/archive sync operations instead of wrapping that stub | Collectors publish continuously to HQ/M1; there is no manual trigger to expose and the stub is not wrapped. Settings Sync explains the model |
| POST `/api/monitor/alerts/:id/dismiss` (`src/web.ts:1297`) | Map the real native alert store before exposing dismissal; do not acknowledge a nonexistent monitor | No native alert store exists; explicitly unavailable (Settings note). Health attention notes are read-only |
| POST/DELETE `/api/dev/mock`, POST `/api/lint`, `/api/log` (`src/web.ts:1304,1311,1319,1343`) | Two mock operations are devMode-gated; lint is a path-scoped read; log is app observability ingestion. Retain their actual dev/integration purpose rather than publishing a generic write proxy | Development-only; explicitly listed as not part of the Web (Settings note). No native Web exposure |
| Configuration editing (explicit owner request) | Old `settingsPage` displays config and edits aliases; no generic config-update route was found in the baseline. Native `setSourceEnabled` already writes through the gate. Map editable settings to the live Swift configuration owner, including source controls; do not revive retired Node configuration | Source enable/disable GET/POST and UI delivered locally (114 script / 7 real-composition-service / 56 remote checks); D14 summary/title/embedding/audit settings locally verified (173 UI / 9 native / 14 remote); installed acceptance pending |

The Web implementation needs explicit write authorization and narrowly typed
operations. Existing viewer sessions must not silently acquire writer authority.
Reuse Swift service methods and their gate; do not forward arbitrary commands,
SQL, paths, or settings keys from the browser.

## HQ deployment and residual risk (2026-09-13)

Deployed through `output/web-parity-20260913/build-web-parity-packages.py` and
`activate-web-parity-role.py` (package name from `WEB_PARITY_PACKAGE`):

| Role | LaunchAgent | Active package | Rollback job |
|---|---|---|---|
| service-index | `com.engram.service-index` | `service-index-web-parity-20260913-r17` (EngramServiceCore `369f3ddd…5d83d`, activated 2026-09-14 09:46:58; `agents=all/only` driver pins). Earlier 2026-09-14 packages, oldest first: r9 (`ByteKey`), r10 (children `COLLATE`), r11 (`session_files` backfill), r13 (children plan, `ec01f34b…30cdf3`), r14 (file-activity read path, `e7b7dad0…7755d4`), r15 (`983f129e…4e4d3`), r16 (`0bc482eb…4fe32`); r12 built, never activated; r8 framework `79251d7d…b61097` before 2026-09-14. The launcher binary `40c33aa4…a754de` is shared by r9–r17 because the code lives in the framework. | `state/service-index/persistent/web-parity-20260913-r17-job-before.plist` (r16 job), and one `…-rN-job-before.plist` per earlier activation down to `…-r8-job-before.plist` (pre-parity job) |
| remote-server | `com.engram.capture-core.receiver` | `remote-server-web-parity-20260913-r5` (binary `704a0c34…cea1da`) | `state/remote-server/persistent/web-parity-20260913-r5-job-before.plist` |

Roll back by restoring the `-job-before.plist` over the LaunchAgent and
`launchctl kickstart -k gui/$UID/<label>`. The editor credential lives only in
`state/remote-server/persistent/editor-credential.txt` (0600), the role
`environment.json` and the job's `EnvironmentVariables`.

Verified on `https://macmini-hq.tail1cb16.ts.net:8443/web/`: login/logout,
all five pages, ranked search with `<mark>` highlights (Latin, CJK, multi-token),
alias add-then-delete write round trip, AI settings form with the saved
`disabled` protocol and save enabled.

HQ-scale fixes shipped in r5/r8 (details in `CHANGELOG.md`): staged-CTE
keyword search (`xcodegen generate` 1.41s cold / 0.35s warm, was 503 at 8s),
`<mark>` rendering without HTML parsing, `aiProtocol: disabled` accepted by the
typed settings surface, tool-analytics memoization and direct SHA256 digests;
r9 (service-index only) adds the `ByteKey` fix for `groupBy=session`, r10 the
children `COLLATE` removal (explicit `COLLATE` had disabled multi-index OR, so
the Child sessions tab returned 503 on HQ). The "0.215s cold" recorded for r10
was measured on an analysed copy; the live database has no `sqlite_stat1`
and r10/r11 still scanned every visible session there (1.53s). r13 de-indexes
the three privacy terms in the children statement with unary plus so the
multi-index OR is the only cheap plan without statistics: 0.088s first /
0.013–0.019s uncached through the remote server. r14 removes the
`session_files` sort and the per-path label/key work from the file-activity
read path (Files 503 → 0.38–0.96s). r15–r17 pin the `sessions` driver for
`agents=all` / `agents=only` (list, total, tools, files) to the skip-excluding
partial index and the page re-check id batch to the primary key: Sessions
"All" 1.85s → 0.07s, "All" + query 1.6–1.8s → 0.13–0.32s, Tools `all` 503 →
0.38–0.59s, Files `all` 503 → 1.14s (details in `CHANGELOG.md`).

Residual risk, all pre-existing at HQ scale and now measured:

- Two-scalar search tokens (`测试`, `go`) — **closed in worktree 2026-09-15,
  not deployed.** Metadata list no longer unbounded-LIKE `sessions_fts`
  (empty page + `query_too_short`). Search `keywordSearch` bounds sub-trigram
  LIKE via recency/`fts_map` + `LIMIT` (`shortQueryHitCap`). Live HQ 5–6s
  numbers were not re-measured. See `CHANGELOG.md` 2026-09-15 residuals.
- `/web/api/tool-analytics?groupBy=session` (fixed in r9, 2026-09-14): the
  cause was `Data.hash(into:)` hashing only the first 80 bytes, which made the
  `Data`-keyed group dictionary and session sets degrade to linear probing on
  HQ's 196-byte shared-prefix session ids; `ByteKey` now hashes every byte.
  Warm answers are 0.73–0.90s (tool 0.29–0.55s, project 0.33–0.57s). The
  earlier I/O diagnosis and covering-index follow-up are withdrawn. What
  remains: the first request after a service restart measured 1.92s, close to
  the 2s metadata deadline, so one 503-then-retry is still possible right after
  an activation.
- `com.engram.remote-server` (`~/.engram-remote/bin/run-engram-remote`) is an
  unrelated Python job on this host; it does not serve port 18787.
- `session_files` (fixed in r11, 2026-09-14): the table was empty because the
  startup repair's candidate query took ~15s on HQ and the 2s batch deadline
  threw before the first head; `CaptureIngestFileActivity` now walks
  `capture_ingest_generations` in order via `CROSS JOIN` and keeps partial
  batches on deadline. r11 backfilled 38,779 heads into 190,039 rows in one
  traversal. `/web/api/file-activity` then cost 2.00s and returned 503 on
  every request (Stats → Files unusable); r14 removes the statement's
  `ORDER BY`, derives labels only for the returned page and memoizes path
  keys — HQ timings after activation are in the `CHANGELOG.md` top entry.
- The HQ `index.sqlite` has never been `ANALYZE`d (no `sqlite_stat1`), so every
  Web statement is planned with default estimates. The children fix works
  around that for one statement. Measured 2026-09-14 on a `VACUUM INTO` copy
  (never the live file): `ANALYZE` takes 3.5s and lets the original children
  statement pick the multi-index OR by itself, but the pre-r11 repair candidate
  query stays at 2.06s with statistics and an approximation of the sessions
  first-page statement moves from 1ms to 18ms with a temp B-tree sort. Plans
  shift both ways, and the plan-asserting tests run on statistics-free
  fixtures, so a database-wide `ANALYZE` / `PRAGMA optimize` is not adopted;
  per-statement plan fixes remain the approach (children: unary plus on the
  privacy terms; `agents=all/only`: `INDEXED BY` the skip-excluding partial
  index, id batches pinned to the primary key). Files `agents=all` covering
  partial `idx_sessions_activity_id` landed in schema + producer EXPLAIN tests
  (2026-09-15 worktree); **not migrated on HQ**.
- `/web/api/overview` omitted `limit` — **closed in worktree 2026-09-15, not
  deployed.** Default is now 2 (UI page size). Historical HQ omitted-50
  measurement was 2.85s / 503; UI already paged `limit=2`.
- Health's "Parsed" vs "Index ready" — **closed in worktree 2026-09-15, not
  deployed.** Labels are `"Parsed (includes skip)"` / `"Indexed for search"`
  plus a note that skip-tier Parsed is not a search backlog. Skip still has
  no FTS job (`ensureCurrentCaptureFTSJob` unchanged).
- Health Cursor quarantine — **closed in worktree 2026-09-15, not deployed.**
  Copy states quarantined counts include empty transcripts
  (`parse.noVisibleMessages`), not a Cursor-only parser failure. No adapter
  change. Historical HQ: all 577 ledger quarantines were that class
  (claude-code 473, cursor 57, …).

## Execution

1. Slice A: preserve existing singular filter compatibility, add plural filters,
   native-ID lookup, agent selection and scalar message counts. Parent owns
   Web UI and JS behavior tests; Herdr Cursor owns typed models/client, metadata
   producer/handler, HTTP routes and their scoped tests.
2. Add paged facets and native aggregate/status/settings reads; restore old
   navigation and picker interactions against those actual endpoints.
3. Finish the remaining read-capability mappings and the explicitly approved
   legacy mutation scope above. Verify complete pages and workflows, not placeholder tabs.
4. Build compatible role packages and verify locally through actual HTTP/IPC
   plus desktop/mobile rendering. Present the concrete deployment target and
   rollback before requesting any new deployment authorization.

Each behavior fix begins with a failing repro; run focused tests and relevant
integration checks. Do not repeat unchanged long performance trials as a
precondition for every small UI change. Current full parity remains unproven
until each applicable row has source-backed end-to-end evidence. No commit,
push, release, or unrelated cleanup is included in this task.

Baseline: `output/web-parity-20260913/before/manifest.json` preserves the dirty
starting contents of the11 initially owned files. Existing earlier agents'
changes remain intact. No Docker runs on this Mac.
