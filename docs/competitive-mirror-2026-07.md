# Competitive Mirror: Agent Sessions, 2026-07

Workflow-generated and adversarially verified. Window 2026-05-24 .. 2026-07-24 (their shipped range is v3.8.1 2026-05-27 through v4.6.4 2026-07-21). Citations prefixed `as-main/` resolve against a read-only snapshot of the rival at `origin/main` @ v4.6.4, reproducible with `git -C <agent-sessions-clone> archive origin/main | tar -x -C <dir>`; history read from the clone itself (`https://github.com/jazzyalex/agent-sessions`). Prior art: `docs/competitive-relaunch-2026-06.md`.

---

## TL;DR

1. Agent Sessions cut **19 tags in 55 days**, every one with the same release triple (public copy, version bump, appcast) and hand-written user-voice notes (`as-main/docs/CHANGELOG.md:7-260`).
2. Engram's last **published** release is v1.0.3 (2026-05-07), 78 days and 1,341 commits ago. v1.0.4 was tagged 2026-07-09 and never published; 1.0.5 is built locally as `1.0.5 (1340)`. This is a decision, not a tooling gap (`docs/TODO.md:31-33`, `docs/roadmap.md:65-68`). Compounding it: Engram ships **no updater at all** — zero `SU*` keys, zero Sparkle — so their 19 tags reached users as 19 updates while ours would reach users as 19 manual downloads (UX-12).
3. On mechanism Engram is ahead almost everywhere they overlap: shadow-table FTS rebuild that never blanks search, ~2,555 Swift tests blocking on every PR, a machine-checked invariants ledger, a 5-reason typed degradation vocabulary. Their entire CI is a 29-line build-only job (`as-main/.github/workflows/ci.yml`).
4. On **finishing** they win. Nearly every finding below is a last-mile defect on shipped Engram machinery, not a missing capability.
5. The sharpest symbol: `.restartService` is declared, observed, and implemented, with a source comment claiming two UI surfaces post it. Verified today: repo-wide grep returns 5 lines and **zero posters** (`macos/Engram/App.swift:152`).
6. Three published Engram numbers are wrong or meaningless: `get_context` serves superseded insights, `get_insights` over-projects monthly spend up to 4.3x, and source health is orange on **18 of 21 sources** by design (measured on the live DB today).
7. The one genuinely absent *program* is vendor format-drift monitoring, and it targets exactly our claimed moat: 17 adapters, 34 format docs, all stamped `Last researched: 2026-06-21`, no script reads them.
8. The one measured feature gap: Codex stamps parentage deterministically and `CodexAdapter.swift:623` hardcodes `parentSessionId: nil`. 481 indexed rollouts are mis-parented; 389 carry a heuristic suggestion matching the vendor-stamped parent in **0** cases.
9. Onboarding never says "MCP" (`grep -rni mcp macos/Engram/Onboarding/` returns 0), and closing the window instead of clicking through re-shows onboarding forever.
10. The public repo description still advertises "TypeScript MCP server" with a `web-ui` topic for a product whose TypeScript runtime was deleted (verified via `gh repo view`).
11. **Do first** — backlog rows **0, 1, 2, 6, 18, 22, 23**. The table below groups by category then effort, so these are *not* the first seven rows: (a) the publication decision itself (row 0, an owner decision, not engineering); (b) `get_context` superseded filter; (c) source-health denominator; (d) Codex native parent signals + re-parse migration; (e) adapter format-drift baseline; (f) publish 1.0.5 with a user-language release note and a corrected repo description.
12. Do **not** copy their quota cockpit, their $/h burn meter, their Codex side-chat log reconstruction, or their NSTableView transcript. Reasons in "Where the mirror flatters us".

---

## What Agent Sessions shipped in the window

Source: `as-main/docs/CHANGELOG.md` (newest first) plus `/usr/bin/git -C /Users/bing/-Code-/agent-sessions tag --sort=-creatordate`.

| Version | Date | Theme | One line |
|---|---|---|---|
| 4.6.4 | 07-21 | Simplification | Retired Compact and Full cockpit modes; Quota Meter is the only mode (`:7-16`) |
| 4.6.3 | 07-20 | Honesty | Footer usage toggles actually worked; usage-source note stops breaking layout (`:18-24`) |
| 4.6.2 | 07-20 | Parsing | Codex guardian subagents get real parentage + one-time forced rebuild; Cowork/sandbox badges; subagents-of-subagents stop vanishing from the list (`:26-43`) |
| 4.6.1 | 07-19 | State honesty | Meter stops claiming "no active session" while holding fresh data; toolbar hard-probe button (`:45-54`) |
| 4.6 | 07-16 | Auth fallback | Paste-a-cookie claude.ai web usage path when the CLI is absent (`:56-69`) |
| 4.5 | 07-15 | Activation | Per-session $/h; the Quota Meter offers itself as a card in the session list (`:71-88`) |
| 4.4 | 07-13 | Refusal | OpenAI removed Codex's 5h window; shows token throughput instead of a wrong number (`:90-97`) |
| 4.3.2 | 07-12 | Perf | Cached per-file parse; idle CPU cut sharply (`:99-105`) |
| 4.3.1 | 07-10 | First run | Single-screen first run, What's New panel, one-click "Fix" on every usage surface (`:107-122`) |
| 4.3 | 07-09 | Never cry wolf | Cause-aware degradation, cold-start fallback fix, no-CLI remediation ladder, probe hardening (`:124-148`) |
| 4.2 | 07-06 | Transcript | Rebuilt structured transcript with role filters and ▲▼ navigation (`:150-159`) |
| 4.1 | 07-03 | Perf program | "The Instant release": instant transcripts, instant sort, indexed FTS, quiet idle (`:161-177`) |
| 4.0 | 06-28 | Features | Session Runway, Codex side chats, Antigravity provider, archived-Claude restore, dynamic workflows (`:179-205`) |
| 3.9.3 | 06-12 | Export | Markdown export with assets folder and readable structure (`:207-214`) |
| 3.9.2 | 06-10 | Alerts | Freshness-aware run-out predictions with a dedicated Preferences pane (`:216-224`) |
| 3.9.1 | 06-05 | Menu bar | Live status label and Hide-Dock-icon fixes (`:226-229`) |
| 3.9 | 06-04 | Quota Meter | Always-on 5h/weekly usage window; limit notifications; format coverage refresh (`:231-249`) |
| 3.8.2 | 05-28 | Formats | Hermes 0.15 state DB, Pi prebump validation, OpenClaw exclusion (`:251-254`) |
| 3.8.1 | 05-27 | Resume | Warp/WarpPreview resume for every supported agent; shared terminal selection (`:256-259`) |

Pattern: roughly one third of their window is *honesty engineering* (4.6.3, 4.6.1, 4.4, 4.3), one third perf and parsing, one third onboarding and packaging. Almost nothing is a new capability.

**The changelog is not the whole window.** `v3.8..origin/main --no-merges` is 400 commits; ~68 of them land in three programs the release notes never mention, because none of the three changes the app: **18** commits of GitHub repo-triage automation (`tools/triage/`, launchd, a tool-less confined agent — see "Where the mirror flatters us" #10), **18** of site/blog/SEO/analytics (`docs/blog/`, the voice guide `625047e9`, GoatCounter `252671cf` — see UX-11), and **22** touching cross-session handover (`tools/handover/`, `/handover` skill `2954f390`, per-session `docs(handover)` entries). Read the release table for what they shipped to users; read the commit log for where their engineering attention actually went. Two of those three programs are adjacent to Engram's own category.

---

## Section 1: Features worth borrowing

Judged against Engram positioning (MCP-first cross-tool memory), not against feature parity.

### F1. `get_context` must not hand agents superseded memory
- **What.** The flagship MCP read path runs raw FTS over `insights` with no `superseded_by IS NULL` predicate, no lifecycle ranking, no wing scoping, capped at 5, while `get_memory` filters and lifecycle-ranks the same rows.
- **Engram today** (verified this session): `macos/EngramMCP/Core/MCPDatabase.swift:1513-1516` calls `searchInsightsFTS(query:limit:5)`; `:1959-1998` has neither the CJK LIKE branch nor the MATCH branch filtering `superseded_by`. Contrast `:674-680`. Same leak in `search`'s insight rows at `:1070-1080`, which additionally return bare content strings with no id and never increment `access_count`.
- **AS evidence.** `as-main/tools/handover/SKILL.md` treats supersede as a first-class status (`superseded-by:<date>`) enforced by `handover-lint.sh`. **Provenance: the principle transfers, the defect is ours.**
- **Change.** Add the predicate to both branches of `searchInsightsFTS`; emit id + importance + type on `search` insight rows so an agent can cite and delete them.
- **Effort S. Impact high** (this is the tool the Claude Code plugin's SessionStart hook calls). **First slice:** one WHERE clause plus a `*_repro` asserting a superseded insight never reaches `get_context` output. No existing test covers get_context insight injection.

### F2. A projection that refuses instead of guessing
- **What.** `get_insights` accepts an arbitrary `since` and then divides by a hardcoded 7, so a 30-day window over-projects monthly spend by ~4.3x, and that number gates the `>$50` "Monthly pace" advice.
- **Engram today** (verified verbatim): `macos/EngramMCP/Core/MCPInsightsTool.swift:5-7` `let effectiveSince = since ?? iso8601DaysAgo(7)` then `let projectedMonthly = (totalSpent / 7.0) * 30.0`; advice at `:24-25`. The default path is correct; only explicit-window callers are wrong, and `docs/mcp-tools.md:373-375` publishes that window as supported.
- **AS evidence.** `as-main/AgentSessions/CodexStatus/UsageDisplayFormatter.swift:81-230`: `UsageLimitProjectionTracker` refuses by default with 11 named `lastDiagnostics` reasons and a retention window that clears a stale projection outright.
- **Change.** Derive `windowDays` from `effectiveSince`; below ~3 days emit no figure and one refusal reason inside `content`. Do **not** add structured fields; `MCPOutputSchemas.swift:67-69` declares `additionalProperties:false, required:["content"]`.
- **Effort S. Impact medium. First slice:** arithmetic fix plus a repro asserting a 30-day `since` is not 4.3x the 7-day value. `EngramMCPExecutableTests.swift:2981` already calls `get_insights` with an explicit `since`; note `contextNow()` is private at `MCPDatabase.swift:2540`, so expose it or the test is non-deterministic.

### F3. Stop rendering a by-design exclusion as degradation
- **What.** `sourceHealthStatus` returns `"partial"` whenever `searchableSessionCount < sessionCount`, but skip-tier sessions have their FTS rows deleted by design, so the badge is near-permanent noise.
- **Engram today** (verified verbatim): `macos/EngramService/Core/EngramServiceReadProvider.swift:1842`; denominator at `:1011-1017` counts every non-hidden session with no tier filter; numerator at `:1696-1706` is `COUNT(DISTINCT f.session_id)`; FTS rows for skip are deleted at `macos/EngramCoreWrite/Indexing/StartupBackfills.swift:843,:912`. Rendered as a bare uppercased pill with no tooltip at `macos/Engram/Views/Pages/SourcePulseView.swift:511-528`.
- **Measured today** on `~/.engram/index.sqlite`, reproducing the provider's own two queries: **18 of 21 sources** report searchable < total. claude-code 1,180/18,370 (17,124 skip); codex 628/5,762; glm 0/2,229; deepseek 0/526; doubao 0/24. The only three healthy sources are the archived default-off ones (cline 3/3, iflow 2/2, lobsterai 1/1). **Contradiction resolved:** one draft reported message-level figures (228,070/245,260) and both drafts said "all 21"; the correct unit is sessions and the correct count is 18 of 21.
- **AS evidence.** `as-main/AgentSessions/CodexStatus/UsageStaleCheck.swift:35-44` (`UsageLimitAbsenceCopy`, one enum so four surfaces cannot drift); `as-main/AgentSessions/CodexStatus/ClaudeAuthClassifier.swift:17-71` (an alarming verdict requires >=2 genuine absences >=60s apart; ambiguous renders nothing); `as-main/docs/CHANGELOG.md:97` (4.4: "shows a clear 'can't verify' instead of displaying a wrong number").
- **Change.** Exclude `COALESCE(tier,'normal') = 'skip'` from **both** numerator and denominator. Do **not** use `searchableTierSQL`: it also excludes `lite`, whose rows *are* in FTS, creating a cancelling blind spot. Add a `healthReason` string to `EngramServiceSourceInfo` (its init params are already fully defaulted with `decodeIfPresent`, `EngramServiceModels.swift:484-565`, 7 construction sites).
- **Effort S. Impact medium. First slice:** the denominator swap plus a test asserting a source whose only unindexed sessions are skip reports `healthy`.
- **Adjacent, file separately:** `Search N%` counts a session searchable at >=1 FTS row (`:1696-1706`), so a 38,974-message session with 3 rows reads as fully covered. That interacts with `IndexJobRunner.swift:239` (10,000-message cap) and `:259-267` (`.messageLimitExceeded` terminal), a deliberate Wave 7A L05 decision. It needs new evidence, not a mirror finding.

### F4. Read Codex's native spawn signals instead of guessing
- **What.** Codex stamps parentage deterministically in three redundant places; Engram reads none of them, so all Codex hierarchy falls to a Layer-2 heuristic that cannot be right.
- **Engram today** (verified verbatim): `macos/Shared/EngramCore/Adapters/Sources/CodexAdapter.swift:623` is `parentSessionId: nil`. Our own `docs/session-formats/codex.md:718-732` already documents the field family as "NOT consumed by Engram".
- **Measured** on the local corpus: 635 of 1,099 rollouts carry `payload.source.subagent.thread_spawn`; 637 yield a deterministic child->parent pair; 481 of those are indexed with `parent_session_id IS NULL`; 389 carry a heuristic `suggested_parent_id` matching the vendor-stamped parent in **0** cases. That is structurally guaranteed: `StartupBackfills.swift:1621-1631` draws parent candidates only from claude-code.
- **AS evidence.** `as-main/AgentSessions/Services/SessionIndexer.swift:2013-2041` (String / `thread_spawn` / `other` / `subDict.keys.sorted().first` fallback, then `parentSessionID ??= payload["parent_thread_id"]`), shipped v4.6.2 with a mandatory one-time rebuild (`as-main/docs/CHANGELOG.md:26-43`).
- **Change.** A `parseSubagent(meta:)` helper feeding `NormalizedSessionInfo.parentSessionId` and `effectiveRole`, with unconditional fallback to top-level `parent_thread_id`; skip `state_5.sqlite`. **Must include** a one-time migration clearing the 389 wrong suggestions and forcing re-parse of already-indexed rollouts: unchanged size/mtime means new adapter code never runs on them.
- **Effort M. Impact high** (measured, not asserted). **First slice:** adapter helper plus a fixture covering all four `source` shapes.

### F5. Run adapter format compatibility as a monitored program
- **What.** 17 adapters, 34 reverse-engineered format docs, all stamped `Last researched: 2026-06-21`, no script or workflow references `docs/session-formats/`, and CLAUDE.md codifies "adapters silently skip failures". A vendor schema change degrades to quietly-missing sessions, which for a memory layer means an agent gets a confidently incomplete answer.
- **AS evidence.** `as-main/scripts/agent_watch.py:550` (`_jsonl_schema_fingerprint`), `:1322` (baseline excluding `schema_drift` paths), `:1396` (`_schema_diff` -> unknown_types/unknown_keys), `:182,:252` (sample-freshness gate); `as-main/docs/agent-support/{agent-support-matrix.yml,monitoring.md}`; `as-main/docs/agent-json-tracking.md:24,27` records two real drifts caught (Copilot 1.0.65 `auto_mode_resolved`; Codex 0.144.x `world_state`). `as-main/docs/agent-support/README.md:23`: "Treat both parser schema drift and discovery path-layout drift as release blockers." Run manually, weekly, not in CI.
- **Engram today.** `scripts/check-adapter-parity-fixtures.ts` proves only that our own generator regenerates deterministically; it cannot see upstream change. `file_index_state` (`macos/EngramCoreWrite/Database/EngramMigrations.swift:163-182`) already persists `parse_status`/`failure_kind` per file per source, written on every `ParserFailure` (`SwiftIndexer.swift:323-331`), and nothing reads it.
- **Change,** in order:
  - (a) `scripts/check-adapter-format-drift.ts`, local not CI (a GitHub runner has no `~/.claude/projects`): fingerprint the newest **real** session per source against a committed `baseline.json`. Do **not** diff against `tests/fixtures/adapter-parity/`; those inputs are synthetic string literals emitted by `scripts/gen-adapter-parity-fixtures.ts:186-270` and would yield near-total false positives.
  - (b) A freshness gate so a green fingerprint over stale evidence reports `blocked_stale_sample`. Engram has a better key than AS's binary mtime: the vendor version is embedded in samples (`tests/fixtures/adapter-parity/claude-code/.../sample.jsonl:1` pins `"version":"2.1.58"` while the format doc researched 2.1.146-2.1.185), and the doc stamp is a second axis.
  - (c) `docs/session-formats/support-matrix.yml` with `max_verified_version` and `last_checked_utc`, gated on staleness rather than row presence (a presence check rots exactly like the 2026-06-21 stamp).
  - (d) `macos/EngramCoreTests/AdapterSchemaDriftTests.swift`, one named test per observed drift, mirroring `Stage0GoldenFixturesTests.swift:37,:115,:191`; seed from Codex `world_state` and Copilot `auto_mode_resolved`/`usage_checkpoint` (both absent from Engram; Claude `mode` is already covered at `AdapterMessageCountTests.swift:1877`).
  - (e) Discovery-path contracts declared in `SourceCatalog.swift:26-43` rather than a competing YAML.
- **Effort M. Impact high. First slice:** the fingerprinter plus committed baselines for claude-code and codex only, plus an `unknownRecordKinds` counter in `ClaudeCodeAdapter` (the allowlist at `:674-678` currently drops any new record type with zero signal).

### F6. Surface the parse failures we already record
- **What.** `file_index_state.failure_kind` is written and never read. A vendor rename makes every file throw `.noVisibleMessages`, classified terminal (`SwiftIndexer.swift:657-663`), with no counter and no surface.
- **Change.** A GROUP BY in `EngramServiceReadProvider`, a `drifted` value on the source DTO, a chip in `SourcePulseView`, and a field on MCP `stats` so an agent can know its own memory is degraded. No new table, no migration.
- **Effort S. Impact medium. Honest limit:** this catches total drift only. A renamed record kind that still parses produces no `ParserFailure` and needs the adapter-side unknown-record counter from F5.

### F7. Make first run and activation name MCP
- **What.** Onboarding is Welcome / Sources / Full Disk Access / Ready. `grep -rni mcp macos/Engram/Onboarding/` returns **0** (verified). A user who completes it has a session browser and no idea their agent can call `get_context`.
- **Engram today.** `MCPSetupGuideView` has exactly one call site, `SourcesSettingsSection.swift:22`, inside a `GroupBox("MCP Client Setup")` filed under the **Data Sources** settings category (`SettingsView.swift:4-33`). An MCP client is not a data source. `SourcesSettingsSection.swift:544` hardcodes `/Applications/Engram.app/Contents/Helpers/EngramMCP` and never consults `Bundle.main.bundleURL`, even though `EngramCLIContextCommand.mcpHelperCandidates` (`macos/Shared/Service/EngramCLIContextCommand.swift:129-161`) already resolves dynamically and is compiled into the app target (`macos/project.yml:161-163`). `SourcesSettingsSection.swift:606` still advertises "Node MCP and daemon HTTP settings are legacy rollback paths for Stage 3". The plugin shipped in `cb6bffc3` with 17 files changed, none under `macos/Engram/Views/` or `Onboarding/`.
- **AS evidence.** `as-main/AgentSessions/Onboarding/Views/QuotaMeterPromoView.swift:1-27` plus `OnboardingListTopSlot.swift:26-33`, shipped `60fb2e49` (2026-07-14). Their rule (4.5, `docs/CHANGELOG.md:76`): "If you have Codex or Claude sessions but have never switched it on, a card in the session list explains what it does and turns it on in one click." The card is the explainer *and* the consent screen; the source documents why it cannot simply open the window ("we would be advertising the feature and delivering an empty box"). Covered by `AgentSessionsTests/OnboardingQuotaMeterCardTests.swift`.
- **Change.** A HomeView activation card gated on `indexed sessions > 0 && no MCP client configured`, one sentence on what `get_context`/`search`/`save_insight` give the agent, linking to the guide or running the plugin install. Derive the helper path from the existing resolver. Delete the stale Node sentence. Add onboarding step 5. The Settings-category move lands in IA territory explicitly deferred as `sources-sync-3` (`docs/reviews/alignment-design-2026-06-14.md`), so treat it as optional.
- **Effort M** overall. **Impact medium-high. First slice:** derive the helper path from `Bundle.main.bundleURL` and delete the Node sentence. Two edits, both pure correctness.

### F8. Correct prices without shipping a binary
- **What.** The pricing table is a compile-time constant (`macos/EngramCoreWrite/Indexing/SessionCostPricing.swift:12`, `tableVersion = "3"`), and `cost_usd` feeds MCP `get_costs`, the shipped budget notifications, and the cost-optimization insights.
- **AS evidence.** `as-main/AgentSessions/CodexStatus/RunwayPriceTable.swift:58-77` with an `updated >= loaded` acceptance rule, a documented rationale for accepting equal dates, and a schema-version gate; `as-main/docs/prices.json`.
- **Change, local half only for v1.** Read `~/.engram/prices.json` if present, applying the same `adopt()` acceptance rule, in `EngramCoreWrite`. Skip the remote fetch: a default-OFF network fetch fixes nothing for the default population and would require amending `docs/PRIVACY.md:73-77`. Make the effective pricing version `tableVersion + manifest.updated` so corrections trigger the existing full recompute; new models land free via the existing `COALESCE(c.cost_usd,0) = 0` predicate. The schema must carry the `.threshold(272_000, ...)` tier; AS's four-flat-doubles shape cannot express it.
- **Effort S. Impact medium, compounding.**

### F9. Disclose unpriced cost rows instead of silently zeroing them
- **What.** `computeCost` correctly returns nil for an unknown model and stores NULL (`SessionCostPricing.swift:113-118`), but both readers do `SUM(cost_usd)` beside `COUNT(*)` with no disclosure field (`macos/EngramMCP/Core/MCPDatabase.swift:231-238,:2346-2357`; `EngramServiceReadProvider.swift:1140-1155`), test-locked at `EngramServiceCoreTests/EngramServiceCostsTests.swift:125-144`. Measured on the live DB: 1,929 of 26,193 token-carrying `session_costs` rows unpriced, 7.6% of tokens.
- **Provenance.** AS returns `unpriceableIDs` (`CodexRunwayModel.swift:1013-1018`) only to *filter rows out*; they never disclose a count either. The drop-not-zero half we already do. The disclosure half is Engram's own 2026-06-10 audit recommendation (`docs/reviews/2026-06-10-multi-expert-audit.md:1677`) that never shipped.
- **Change.** Add `unpricedSessions`/`unpricedTokens` to both readers and both DTOs, **split by cause**: 867 of the 1,929 rows carry an empty model string (a write-time attribution defect), 781 carry `gpt-5.6-sol` (a pricing-table gap). One counter conflates two bugs.
- **Effort S. Impact medium. First slice:** the MCP `get_costs` fields plus a repro.

### F10. Suppress Resume where the command cannot succeed
- **What.** 14,991 Claude subagent rows offer Resume and Copy-Resume-Command; the emitted command names an id no session owns.
- **Engram today** (verified): `EngramServiceReadProvider.swift:1364-1372` selects 12 columns with no `agent_role` and no `parent_session_id`, then dispatches on `source` alone at `:1436-1445`; `macos/Engram/Components/ExpandableSessionCard.swift:228-236,:263-271` pass the actions unconditionally.
- **AS evidence.** `as-main/AgentSessions/Views/UnifiedSessionsView.swift:3129-3149`: `case .claude: return !s.isClaudeWorkflowSubagent`, plus a belt-and-braces guard at the `resume(_:)` entry.
- **Change.** Add the two columns to the SELECT; when `agent_role == "subagent"` return the existing `error`/`hint` form (`EngramServiceModels.swift:926-951`, already rendered by `ResumeDialog.swift:156-168`) naming the parent. Gate the client on `agentRole == "subagent"` specifically, **not** `Session.isSubAgent` (`Session.swift:121` is `agentRole != nil`, which would wrongly kill resume for `dispatched` Codex children whose ids *are* resumable).
- **Effort S. Impact medium.**

### F11. A manual "index now", and stop serving known-stale search results
- **What.** No manual scan trigger exists (73 service commands, none reindex; `triggerSync` is a hard-coded not-implemented stub at `EngramServiceCommandHandler.swift:1483-1495`), the background scan is 15-60 min with no file watcher (`IndexingSchedulePolicy.swift:32-35`), and search is fully FTS-authoritative with no freshness check (`EngramServiceReadProvider.swift:591-692`; `MCPDatabase.swift:2165,:2204`).
- **AS evidence.** `as-main/AgentSessions/Indexing/DB.swift:1810-1848` (`indexedSessionIDsCurrent`, a 3-way join on mtime + size + format_version) and `Search/SearchCoordinator.swift:294-305,:633-648` (stale ids bypass the size gate).
- **Change.** A `scanNow` service command through `ServiceWriterGate`. The cycle runs inside `activityScheduler.performWhenDue`, which exposes no fire-now, so the out-of-band call must reproduce `withBacklogDrainPaused` and the schedule bookkeeping. **If the MCP-freshness argument is the driver, the trigger must be MCP-reachable**; an agent cannot press a Sources-page button. Skip a three-surface coordinator; `SessionActionHandlers.ActionState` already provides the idle -> inFlight machine.
- **Effort M. Impact medium. First slice:** `scanNow` plus one trigger. Currency-aware read second, and note `file_index_state.mtime_ns` *is* the indexed stat, so a self-join is a no-op; you must `stat()` result locators at read time outside the GRDB block and map a failed stat to "reclaimed", not "stale".

### F12. Queued below the line (real, verified, lower ratio this cycle)
- Claude workflow-nested subagents: `ClaudeCodeAdapter.swift:112-119` never descends into `subagents/workflows/`, missing ~31,400 transcripts. M effort; payoff bounded because they all land skip-tier and stay out of search. AS ref `ClaudeSessionParser.swift:1178-1213`, commit `77498434`.
- **Grandchild sessions are absent from the list hierarchy.** Top-level browse filters `parent_session_id IS NULL` (`macos/Engram/Core/Database.swift:181`) and `childSessions` walks exactly one level (`:1373-1388`), so a session whose parent is itself a child appears neither at top level nor under any expanded card. AS shipped the same fix in 4.6.2 (`as-main/docs/CHANGELOG.md:42`, commit `d1d8de2e`, "the list now walks the whole tree"). **Measured today** on `~/.engram/index.sqlite`: 130 such rows (`SELECT COUNT(*) FROM sessions c JOIN sessions p ON c.parent_session_id=p.id WHERE p.parent_session_id IS NOT NULL`), of which **124 are skip-tier and would be hidden anyway** — the real exposure is **6** rows (5 kimi, 1 copilot). They are still reachable by opening the middle child's detail view (`SessionDetailView.swift:761`), so nothing is unrecoverable. Note this is only the *display* side; `validateParentLink` (`EngramServiceCommandHandler.swift:1456-1481`, both `depth-exceeded` returns at `:1470` and `:1478`) deliberately rejects manual depth-2 links, so recursion must be added to the reader without relaxing that write rule. **Impact low on measured data**; file it, do not schedule it. Pagination is *not* a companion defect: 230 parents exceed the 20-child default but `ExpandableSessionCard.swift:248-252` already renders "show N more…".
- Per-turn duration badges: see UX-7 below.
- Byte-offset transcript cursor: see Q4 below.

---

## Section 2: implementation quality gaps

### Q1. Nothing measures the app process
- **What.** Zero `os_signpost` and zero MetricKit hits anywhere under `macos/`.
- **AS evidence.** `as-main/AgentSessions/Support/PerfSignpost.swift`, 186 lines, 30 call sites: `Perf.begin/end` with `@escaping @autoclosure` detail, a 16ms print threshold, a `MainThreadStallMonitor` armed only under `AS_PERF_MONITOR`, and a signature-identical Release no-op shim added in `838c7396` after unguarded spans broke their Release build.
- **Scope it correctly.** Engram **already** ships `ServiceTelemetryCollector` (`macos/EngramService/Core/ServiceTelemetryCollector.swift:97-126`, p50/p95/max/errorCount per IPC command, surfaced live in `PerformanceView.swift` and `TraceExplorerView.swift`), so service-mediated latency is measured. The unmeasured surface is app-local main-thread work: `SessionDetailView.swift:995,:1008,:1036` and `SessionsPageView` paging.
- **Change.** Add `macos/Engram/Support/PerfSignpost.swift` (`#if DEBUG` impl plus Release no-op), an `ENGRAM_PERF_MONITOR`-gated stall monitor, and spans on those four sites only. Do **not** widen `.github/workflows/perf.yml`: its budget enforcement is a bespoke xctest-log parser built around one `measure` block, and the repo is in a release freeze.
- **Effort S. Impact medium-high. First slice:** the shim plus one span around transcript parse. Copy their `838c7396` lesson (ship the Release no-op in the same commit).

### Q2. A failed poll renders as "nothing is running"
- **What.** Three call sites blank a live indicator on IPC failure, so a broken service is indistinguishable from an idle machine.
- **Engram today.** `SourcePulseView.swift:120-127` (`catch { liveSessions = [] }`, section gated by `if !liveSessions.isEmpty` at `:65`); `PopoverView.swift:270-272` (`(try? ...) ?? []`, documented at `:263-265` as intentional silent-fail); `MenuBarController.swift:429-437`, where the catch drops the live dot while keeping the held today count in the same expression.
- **The hard half already ships.** `macos/Shared/Service/EngramServiceStatusStore.swift:21-25,:69-74` defines `ServiceDataFreshness { live / stale(asOf:) / expired }` with a 30-min TTL, consumed honestly at `HomeView.swift:289-296` and `PopoverView.swift:274-297`.
- **AS evidence.** `as-main/AgentSessions/CodexStatus/CodexRunwayModel.swift:418-462` (`RunwayAggregateBurnHold`, 120s TTL); `as-main/AgentSessions/Views/CockpitFooterView.swift:86-93,:105-126,:134-141`; `as-main/docs/CHANGELOG.md:634`.
- **Change.** Reuse the existing enum and `asOfText`; hold last-good across a failed poll, caption it, degrade to an explicit unavailable row past TTL. Do not invent a parallel vocabulary.
- **Effort S. Impact medium. First slice:** `SourcePulseView.loadLiveSessions` plus a repro that a thrown poll does not empty the list.

### Q3. The one-click service recovery is unreachable
- **What.** `.restartService` is declared (`macos/Engram/AppNotifications.swift:8`), observed (`App.swift:155`), dispatched (`:157`) and implemented (`:225`). **Zero posters.** The comment at `App.swift:151-152` asserting that WP09's menu-bar item and the Service-State banner post it is factually false. After 3 failed auto-restarts the launcher emits `.degraded` and never restarts again (`EngramServiceLauncher.swift:236-266`), so a wedged service is unrecoverable without quitting the app. `HomeView.swift:255-274` `serviceStateSection` is two non-interactive rows; `GeneralSettingsSection.swift:105-118` renders `Text("Degraded: ...")`.
- **This is a documented false closure, not a new discovery.** `docs/reviews/alignment-design-2026-06-14.md:1019` specified the trigger surfaces and `:1055` predicted verbatim: "If WP09 lands without the UI trigger, the recovery handler exists but has no visible affordance." WP09's spec never listed it, and `docs/TODO.md` then declared all PR #74 UX follow-ups resolved.
- **AS evidence.** `as-main/AgentSessions/Shared/Views/AuthRemediationBanner.swift:95-100` (one "Fix..." button to one guided dialog), `:212-250` (lettered steps), `:303-311` (`recheck()` re-runs the real fetch and reports "Updated ✓" / "Still unavailable"); `as-main/AgentSessions/Shared/UsageAuthStatus.swift:7-133`.
- **Change.** Post `.restartService` from the HomeView Service State row and the menu-bar NSMenu (**not** the popover; `HomePopoverActionsTests` pins its status-chrome removal), gated on `.error`/`.degraded`. Delete the false comment. Add a test asserting a poster exists.
- **Effort S. Impact medium** (the service mostly self-heals via `EngramServiceLauncher.swift:192-260`; the tail case is total). Do **not** build the full typed-remediation ladder: with one real call site that is an abstraction for single-use code.

### Q4. Transcript paging is quadratic in three places
- **What.** `JSONLAdapterSupport.windowedMessagesWithMetadata` implements offset as `produced += 1; if produced <= offset { continue }` over a freshly-opened `StreamingLineReader` (`macos/Shared/EngramCore/Adapters/Sources/CodexAdapter.swift:420-437`), and `SessionDetailView.swift:1038-1040` feeds `loadedProducedCount` back as that offset. Paging a 10k-message session to the end parses ~105k messages.
- **A byte cursor alone does not make it linear.** `rebuildIndexed()` re-classifies the entire loaded prefix on every page (`SessionDetailView.swift:1005-1018` -> `IndexedMessage.swift:17-27`) and bumps `displayVersion`, re-running the match scan. Three quadratic terms; the cursor removes one.
- **Change.** Add a stop-offset to `StreamMessagesOptions`/`WindowedMessagesResult` and a seek entry point to `StreamingLineReader` (`:38-113` has none), keeping the counted path for `MCPTranscriptReader.swift:330-395`, which pages by random access. Plus append-only `rebuildIndexed`.
- **Effort M. Impact medium** (421 of 33,525 sessions exceed the 800-message threshold, and "Load all" is one click away). **First slice:** the cursor plus a `*_repro` asserting total lines read is O(n).
- **Do not** adopt tail-first cold paint: AS's provisional paint is explicitly throwaway (`ReverseJSONLTailReader.swift:8-9`) and is replaced by a full non-paged parse, which cannot map onto a genuinely paged view without identity reconciliation they deliberately avoided.

### Q5. Bind the shipped binary to the verified commit
- **What.** `macos/scripts/release-verify.sh` checks hygiene, structure, codesign, Developer ID and notarization; nothing records *which commit* produced the bundle, and nothing consults CI. `build-release.sh:66-81` derives the build number from `git rev-list --count HEAD` on a clean tree (verifiable: `rev-list --count cb6bffc3` = 1340, matching the installed `1.0.5 (1340)`), so an implicit binding exists, undocumented and unasserted.
- **AS evidence.** Their QA stamp (`as-main/tools/release/deploy:72,:127,:177`) exists because their tests run only on the maintainer's Mac. Engram's CI-on-tag is structurally stronger, which is why the fix is provenance, not a TTL file.
- **Change.** Inject `git_head`/`git_dirty` **pre-archive** via the existing `$(MARKETING_VERSION)` token pattern in `macos/project.yml:198-209`; a post-export Info.plist edit invalidates the signature `release-verify.sh:129` then checks. Add an opt-in `--require-ci-green`.
- **Effort S. Impact medium.** This mechanizes the verifier `docs/TODO.md:8-33` already owns.

### Q6. Point in-source incident notes at the invariants ledger
- **What.** AS's `CodexRateLimitWindowClassifier.swift:3-18` carries a 16-line writeup of what OpenAI changed, why position-based parsing was the root cause, and which alternative was rejected. Engram already does this at ~19% organic adoption (55 of 292 product files carry rationale comments; `SessionCostPricing.swift:46-48`, `StartupBackfills.swift:1484-1487`, `SQLiteConnectionPolicy.swift:18-29`) and has something stronger they lack: `docs/invariants.md`, 13 machine-checked invariants.
- **Change.** One bullet after CLAUDE.md's repro-tests rule: when a fix site is covered by an invariant, name it in the comment so code points back at the ledger. Drop the proposed lint; `scripts/check-swift-conventions.sh` is four literal `rg` rules with no test-to-fix-site mapping.
- **Effort S. Impact low.**

---

## Section 3: UI/UX and everything else

Engram's interior craft is better than its exterior by a wide margin. The Reduce Motion discipline is the best in either codebase, the Sources page is the most honest status surface in either product, and the transcript viewer volunteers uncomfortable truths. But almost nothing that faces a stranger works, and of 45 shared error/empty surfaces that ship a remediation slot, exactly one passes it.

### UX-1. The find bar destroys the transcript, and lies about zero matches
Two independent defects in one interaction.

- **(a) Rendering.** `macos/Engram/Views/Transcript/ColorBarMessageView.swift:162-170` (verified verbatim): for `.assistant`/`.code`, `if searchText.isEmpty { SegmentedMessageView(...) } else { Text(highlightedText(...)) }`. Type one character in ⌘F and every heading becomes `##`, every table becomes `|---|`, every code card becomes plain text. Engram *does* have real block rendering (`ContentSegmentParser.swift:4-12`: codeBlock/heading/lists/table/hr with a syntax-highlighted code card and a GFM Grid table); it just switches it off. Separately `.user` never reaches `SegmentedMessageView` at all (`:195-199` routes it to the `default:` plain-Text branch), so a user turn containing a fenced diff shows raw backticks.
- **(b) Scan scope.** `SessionDetailView.swift:155` scans `displayIndexed`, the **post-filter** set, while `defaultTypeVisibility` (`:85-89`) shows only user + assistant. On a fresh open 7 of 9 message types are excluded from the scan, so ⌘F for a string inside a tool call returns a flat "no matches" with no signal that anything was hidden. The existing all-hidden state (`:358-368`) fires only when *everything* is filtered out.
- **AS evidence.** `as-main/AgentSessions/Services/MarkdownBodyRenderer.swift:764-776` (`appendMappedRun`: render first, then scan; the append is unconditional so a scan miss can never drop content) plus `Services/RenderedBody.swift:62-70` (`renderedRange(forSourceRange:)`). They paid a full UTF-16 source-map cost precisely so find never degrades the render. Separately `Views/TranscriptBlockListView.swift:497-515` (`autoExpandedByFind` shadow sets) and `:4157-4169` (yellow match-count pill on collapsed cards), shipped `0b70563a`.
- **Change.** (a) Add `.user` to the `SegmentedMessageView` branch (one line); then thread `searchText` into the segment views and paint highlights on the **rendered** `AttributedString` (`String(attributed.characters)`), not by merging raw-source ranges. The parser uses `.inlineOnlyPreservingWhitespace`, which consumes markers, so raw `computeHighlight` ranges misalign. Keep the `NSCache` key on `text` alone; re-keying on `text+query` forces a full re-parse per keystroke and undoes PR #97's memoization. (b) One detached pass over `indexedMessages` partitioned by the existing `isMessageVisible`, rendering "12 more matches in hidden types (Tools, Thinking)" next to the existing partial-load hint, with a tap target that flips those types visible. Bucket by *the gate that hid the message*: `.systemPrompt`/`.agentComm` are gated by `showSystemPrompts`/`showAgentComm`, not by `typeVisibility`.
- **Effort S** for the `.user` line and the hidden-type count, **M** for the highlight rework. **Impact medium-high** (a silent wrong answer on the surface users land on after clicking a search result).
- **Note.** (a) was found internally six weeks ago: `docs/reviews/ux-flow-review-2026-06-14.md:1375` graded it 🟡 Low, `alignment-design-2026-06-14.md:196` deferred it. The rival corroborates a shelved finding; it did not reveal a blind spot.

### UX-2. Make first run terminate, and make it re-enterable
- **What.** `App.swift:199` gates solely on `hasCompletedOnboarding`; `App.swift:288` writes it **only** inside `completeOnboarding()`, reachable only from the final button (`OnboardingView.swift:198`). `App.swift:273` sets `styleMask = [.titled, .closable, ...]` with no `NSWindowDelegate`. A user who closes the window instead of clicking through gets onboarding again **on every launch, forever**, and `NSApp.setActivationPolicy(.accessory)` also lives only on the completion path (`App.swift:291`), so that session is stuck as a Dock-visible app. `MenuBarController.swift:504-560` builds App/Edit/View/Window and no Help menu, so the screen is unreachable after completion.
- **Also:** `OnboardingView.swift:228` probes Windsurf at `~/.codeium/windsurf` while the adapter reads `~/.engram/cache/windsurf` (`SourceCatalog.swift:41`). That is the only genuine drift in the hardcoded list (`lobsterai`'s absence is a test-enforced invariant at `SourcesSyncTests.swift:93`; `minimax` is a Claude-Code-derived source at the same path, so a filesystem probe cannot distinguish it).
- **AS evidence.** `as-main/AgentSessions/Onboarding/Models/OnboardingCoordinator.swift:75-97,:315-327`, plus `WhatsNewPanelView.swift` and `FeedbackPromptView.swift`, shipped `27dd4984` and `53a92fee`.
- **Change.** Install an `NSWindowDelegate` recording completion on `windowWillClose`; add `Help > Show Onboarding`; fix the Windsurf path. Do **not** copy AS's fresh-install-by-artifact-absence: `App.swift:127` spawns `EngramService` before the check at `:199`, and the service is what creates `~/.engram/index.sqlite` (`EngramServiceRunner.swift:126`), so that would be a process-spawn race against your own helper. Skip the default-seeding half entirely; `OnboardingView.swift` writes no defaults today.
- **Effort S (arguably XS). Impact medium. First slice:** the window delegate. Three lines and a regression test; it fixes an infinite re-show loop.

### UX-3. Fix the public claim, then freeze it
- **Engram today** (verified via `gh repo view`): description `"Cross-tool AI session aggregator: TypeScript MCP server and macOS menu bar app"`, topics including `typescript`, `web-ui`, `raspberry-pi`, `homepageUrl` empty. That describes an architecture CLAUDE.md says was deleted. `README.md:7-19` is an internal status memo as the second thing a reader sees. `README.md:117` still promises "之后通过文件监听增量更新" (incremental updates via file watching); there is no watcher, `AppSearchServiceCutoverScanTests.swift:1062-1074` asserts `SessionWatcher.swift` must not exist, and the real cadence is 15-60 min. README contains zero images and zero links to Releases.
- **AS evidence.** `a045d7c5` (2026-07-20) demoted their most-quotable claim with the commit body "Positioning bug, not a distribution one", a two-file diff touching only `README.md` and `docs/index.html`. `as-main/tools/release/validate-release.sh:116-191` then errors if README lacks the versioned DMG link and `Download Agent Sessions ${VERSION}`, loading its agent list from `docs/agent-support/public-agents.json` rather than hardcoding it.
- **Change.** (a) Fix the repo description and topics. (b) Rewrite `README.md:1-19`: positioning sentence, then a CTA row, then "Why Engram is different"; demote `git clone` to `## Build from source`. (c) Delete the false file-watch sentence. (d) Add `scripts/check-public-copy.sh` with a literal denylist (start with `文件监听` / `file watch`) plus source-count and tool-count checks derived from `SourceCatalog.swift` and `docs/mcp-tools.md`, registered in `scripts/invariant-gates.json`.
- **Effort S. Impact medium.** The gate is regression insurance; the counts are currently correct (README already says "14 active + 3 archived" and "27 tools").
- **First slice:** description, topics, and the false sentence. Ten minutes, zero risk. Sequence the CTA row **after** 1.0.5 actually publishes; pointing `/releases/latest` at v1.0.3 today hands a stranger a build predating the 27-tool MCP surface, archive v2, and the plugin.

### UX-4. Stop drawing a limitless share as a quota meter
- **What.** `macos/EngramCoreWrite/Indexing/StartupUsageCollector.swift:224-253` writes "7d token share" / "5h token share" rows with `limit_value NULL, status 'observed'`; `macos/Engram/Views/Usage/PopoverUsageSection.swift:274-280` renders `.green` for any non-critical status, `:333-336` fills `value/100`, `:327-329` prints a bare "62%". Because shares sum to 100% across sources, the busiest source always shows the fullest bar, under a header that says USAGE. In compact mode the metric word is dropped entirely (`:64`, `:112-117`). `resetAt` is threaded through three layers (`:49`, `:68`, `:179`, `:269`) and rendered nowhere.
- **AS evidence.** `as-main/AgentSessions/Views/CockpitFooterView.swift:86-93` (`unavailableForDisplay()` nulls cached values so the meter reads `--`), `:105-126` (four-state `PresentationState`); `as-main/AgentSessions/CodexStatus/UsageStaleCheck.swift:35-44`.
- **Change.** Route `limit == nil && isPercent(unit)` to a plain text row ("62% of 7d tokens"); give the compact row the metric word back; render or delete `resetAt`. **Do not** add a shared absence-copy enum (one call site) or a "configure limits" link: `SettingsView.swift:273-302` already ships a full Usage Limits GroupBox with per-source 5h/weekly fields and `PopoverView.swift:178-189` already links to it from the empty state.
- **Effort S** (~40 lines in one file). **Impact medium.**

### UX-5. Give the app a mouth
- **What.** `grep -rniE "github.com|report.*(issue|bug)|send feedback" macos/Engram --include="*.swift"` returns **0 hits**. `AboutSettingsSection.swift:31-56` exports a redacted diagnostics bundle to disk and stops there. No Help menu exists. The public issue tracker is enabled with zero issues; the eight open PRs are 100% Dependabot.
- **AS evidence.** `as-main/AgentSessions/Onboarding/Views/FeedbackPromptView.swift`, shipped in `27dd4984`.
- **Change.** A Help menu with "Report an Issue" (prefilled GitHub issue URL carrying version + build) and "Show Onboarding"; add "Attach to an issue" beside the diagnostics export.
- **Effort S. Impact low-medium today** (there are no users to hear from), **high the moment a release ships.** Sequence with UX-3.

### UX-6. Verify MCP setup in-app
- **What.** MCP's entire verification surface is a passive `PathExistsIndicator` (`SourcesSettingsSection.swift:599` -> `:230-241`, a bare `FileManager.fileExists`): no exec-bit check, no handshake, no socket check. The only user-initiated probes in Settings are AI "Test Connection" (`AISettingsSection.swift:244-283`) and the archive restore drills (`ArchiveSettingsSection.swift:396`).
- **AS evidence.** `as-main/AgentSessions/Views/Preferences/PreferencesView+Usage.swift:544-547` (3-state `TestState`), `:590` ("Test now"), `:658-661` (`performTest()` documented as end-to-end in the *same source order the app uses*, user-initiated only, never on a timer). Shipped `33fcda27` (2026-07-16).
- **Change.** Rungs: resolve path (reuse `EngramCLIContextCommand.mcpHelperCandidates`) -> exec bit (`isExecutableFile`, `:163-168`) -> real stdio `initialize` + `tools/list` (`invokeMCPGetContext`, `:335+`, already does JSON-RPC with timeout/malformed/processFailed outcomes) -> service socket reachable (`EngramServiceStatusStore`). Report the first failing rung with one specific remedy line.
- **Effort M** but front-loaded on reuse: rungs 1-3 already exist in the app binary; the real cost is remedy copy and tests. **Impact medium. First slice:** rungs 1-2 replacing the passive dot.

### UX-7. Per-turn duration chip
- **What.** "Where did the time go" answered in the transcript header band.
- **AS evidence.** `as-main/AgentSessions/Services/TranscriptTurnTiming.swift:51-106` (`compute(blocks:)`), `:107-113` (nil on negative deltas for clock skew), `:118-131` (bucketed formatter), rendered into a fixed 22pt header band at `TranscriptBlockListView.swift:4107-4116` so it can never change row height. Shipped `f580577f` + `b0fa0a23`; in their release copy at `docs/CHANGELOG.md:152`.
- **Engram today.** `ChatMessage` (`MessageParser.swift:11-18`) has four fields and no timestamp, so the UI cannot see the time the adapter already parsed (`SessionAdapter.swift:71`). But the computation exists one view over: `EngramServiceReadProvider.replayEntries` (`:1571-1604`) diffs consecutive ISO timestamps via `replayDurationMs` (`:1625-1627`) with a skew clamp, plumbed to the app (`ReplayState.swift:12`) and consumed only as playback pacing (`:147-148`).
- **Change.** Add `timestamp` to `ChatMessage` (14 construction sites), walk user-anchored turns, render a trailing chip in the existing `roleHeader` HStack, reusing the replay duration convention. **Scope to turns only**: `MessageParser.adapterMessages` drops `.tool` role records entirely, so the `.toolCall`/`.toolResult` types the transcript shows are content-pattern guesses (`MessageTypeClassifier.swift:50-63`); pairing them would pair heuristics.
- **Effort M. Impact medium.**

### UX-8. Accessibility: the text does not scale
- **What** (verified): `grep -rn "dynamicTypeSize\|ScaledMetric" macos/Engram --include="*.swift"` returns **0**, against **172** `.font(.system(size:))` call sites. The entire primary navigation is fixed at 10.5pt with 8pt section headers (`SidebarView.swift:21,:143-147`) inside a sidebar hard-pinned to `minWidth: 160, maxWidth: 160` (`:46`) with `.lineLimit(1)` and no tooltip. Accessibility is instrumented for tests, not users: **204** `accessibilityIdentifier` vs **19** `accessibilityLabel` and **1** `accessibilityHint`. `TranscriptToolbar.swift` ships ~12 icon-only buttons with one label (`:62`); back (`:42`), font ± (`:140`, `:145`), copy-all (`:152`) and Find (`:164`) have neither label nor `.help()`. `MessageTypeChip.swift:36,42` uses bare `Text("∧")` / `Text("∨")` at 9pt as prev/next controls, which VoiceOver reads as Unicode logic symbols.
- **Change.** `@ScaledMetric` for the type ramp (or semantic `Font` styles), starting with sidebar and transcript body; `accessibilityLabel` + `.help()` on every icon-only control in `Views/Transcript/`.
- **Effort M** for the ramp, **S** for the labels. **Impact low-medium in usage terms, but table stakes for a macOS app that wants to be recommended. First slice:** the ~15 missing labels. An afternoon.

### UX-9. Sweep the remediation slots we already ship
- **What.** `AlertBanner.swift:6` and `EmptyState.swift:8` both declare `var action: (label:action:)? = nil`; across 20 + 25 = **45 call sites, exactly one passes it** (`MigrationHistoryView.swift:68`). `ServiceErrorPresenter.displayMessage(for:)` (`EngramServiceError.swift:56-63`) is called at 2 sites while `localizedDescription` is piped raw into banners 43 times.
- **Change.** Pass an obvious reload closure at the four highest-traffic sites (`SessionsPageView.swift:149`, `ReposView.swift:44`, `SourcePulseView.swift:74`, `TimelinePageView.swift:232`) and route text through `ServiceErrorPresenter`.
- **Effort M. Impact medium.**

### UX-10. Release notes as a human artifact
- **What.** `CHANGELOG.md` is 5,677 lines of agent narrative by design (CLAUDE.md mandates it); `[1.0.4]` alone spans lines 794-5109 (4,316 lines, 165 sub-sections) and `[Unreleased]` already holds 55 sub-entries with titles like `### Fixed: perf-integration residual closeout (2026-07-08, Codex)`. There is no user-readable notes artifact anywhere, so cutting a release means authoring copy from scratch.
- **AS evidence.** Their changelog *is* the public copy, hand-written in user voice (`as-main/docs/CHANGELOG.md:7-16`), parsed per-version by `tools/release/sparkle_release_notes.py::_parse_changelog_sections` and linted for banned internal wording (`:444-475`, which actually bit in `eb1120ce`). `.claude/skills/release-notes/SKILL.md` carries the Iron Rule: "a change earns a line only if it is observable as a difference between the previous shipped release and this one." Verified triple per release: `a2d2baa4` -> `0205be78` -> `0b7a0bc1` for 4.6.4, same shape for 4.6.3, 4.6.1, 4.5.
- **Contradiction resolved.** Two of three drafts proposed `docs/release-notes/<version>.md`; one proposed an in-changelog `### Highlights` block. Take the separate directory: CLAUDE.md mandates the agent narrative in `CHANGELOG.md`, so an in-file human block would be linted against its own neighbours and would not survive the 4,000-line sections.
- **Change.** `docs/release-notes/<version>.md`, 10-30 lines, second person, becoming the GitHub Release body and the future Sparkle description. Assert presence in the existing `validate-release-tag` job (`.github/workflows/release.yml:26-35`, which already holds `$GITHUB_REF_NAME` and fires before any build work). **Not** the invariants ledger, which is a path-existence gate with no tag awareness.
- **Effort S to set up; the recurring per-release editorial cost is real and is not S** (AS 4.6.2 is ~10 dense hand-written paragraphs). **Impact medium.** Note the notes artifact has only two consumers today — the GitHub Release body and a future updater feed (UX-12); Engram ships no updater, so do not scope it as "the Sparkle description" yet.
- **Framing correction.** Notes are not why releases have not shipped. `docs/roadmap.md:65-68` names missing Developer ID / notarization secrets and no distribution surface; `docs/TODO.md:31-33` explicitly withholds authorization to tag or publish.

### UX-11. Distribution, marketing surface, cadence
- **Cadence.** AS cut 19 tags in 55 days. Engram's last published release is v1.0.3 (2026-05-07), 78 days and ~1,341 commits ago; v1.0.4 was tagged 2026-07-09 with its Release Gate passed and never published; 1.0.5 is built and locally deployed as `1.0.5 (1340)` with no tag. This is a decision, and it is the root cause of every downstream item in this section.
- **Public product page.** AS ships a full Jekyll site (`as-main/docs/_config.yml`, `Gemfile`, `_layouts/`, `_posts/`, `docs/index.html` 26.7 KB with a `<video autoplay loop muted playsinline poster>` hero, `docs/blog/`, `docs/appcast.xml`, ~34 MB of `docs/assets/`) plus six per-agent SEO guides at `docs/guides/*.html`, titled as the query the user types, with `<meta keywords>` listing the literal on-disk paths. Engram has no `site/`, no `index.html` anywhere, no Pages workflow, empty `homepageUrl`, and zero images in a 519-line README. **Effort L. Impact medium, strictly gated on a published binary**: a landing page whose download button is stale is worse than no page.
- **The asymmetric asset** is `docs/session-formats/`: 34 hand-researched references (codex.md 106 KB citing 2,505 real rollout files across Codex CLI 0.60.1 -> 0.142.0-alpha.6). These are already the best public answer to "where does Codex store session history" and already world-readable, simply unranked and unpackaged. Converting five into search-facing HTML is content-free work. But it creates a currency obligation: all 34 carry the single stamp `Last researched: 2026-06-21`, no script references them, and commit `e30ad4b2` edited `docs/session-formats/vscode.md` the day *after* that stamp without updating it. Publish only with a dated freshness line and a recheck cadence entry (F5c).
- **Hero asset.** AS leads with motion (`docs/index.html:439-442`) because a rate changing over time cannot be shown in a still, and ships light/dark `<picture>` pairs (`as-main/README.md:43-67`). Engram already owns the harder half: `macos/EngramUITests/Helpers/ScreenshotCapture.swift` with 34 committed baselines including dark and zh-Hans, `TestLaunchConfig.swift:43-47` passing `--window-size 1024x681 --appearance light|dark`, plus `scripts/screenshot-compare.ts` diffing, and publishes none of it. The judgment their asset choice implies: **Engram's hero must not be a screenshot of its own window.** That window is a session browser, which is the rival's category and the axis Engram cannot win. The hero is a terminal recording of Claude Code answering with context it did not have before, now demonstrable since `EngramCLIContextCommand.swift:214` emits real `SessionStart` hook JSON. **Effort M** for the capture mode plus README `<picture>` pairs into a new `docs/assets/`; drop `site/index.html` from scope until the site exists.
- **Competitive-intel process.** `docs/competitive-relaunch-2026-06.md` is dated and correctly back-referenced from `docs/roadmap.md:140`, and CLAUDE.md already carries binding positioning rules (the "17 sources is the adapter count" clause). It has drifted in exactly two facts: it says "28 tools" (now 27, since `8b4ab02a` deleted `lint_config` on 2026-07-06) and its P0-1 plugin shipped in `cb6bffc3`. Fix with a dated update block. Ten minutes, not a workstream.

### UX-12. Whatever version a user installs is the version they keep

- **What.** Engram has no in-app update path of any kind. `macos/Engram/Info.plist` is 27 keys with zero `SU*` entries; `grep -rn "Sparkle" macos/ --include="*.swift" --include="*.yml" --include="*.plist"` returns **0**, and so does a grep for `checkForUpdates`/`SUUpdater`/`updateCheck` across `macos/`. A user who installs from a GitHub Release is pinned to that build until they notice a new one and re-download by hand.
- **AS evidence.** `as-main/AgentSessions/Info.plist:33-45`: Sparkle 2 with `SUFeedURL` → `https://jazzyalex.github.io/agent-sessions/appcast.xml`, `SUPublicEDKey`, `SUEnableAutomaticChecks`, `SUScheduledCheckInterval` 86400, `SUAutomaticallyUpdate` true, `SUShowReleaseNotes` true. Every one of the 19 tags in the window closes with a `chore(release): update appcast for <version>` commit (`0b7a0bc1`, `3d2e6df5`, `e70c7d65`, `aa304938`, `caa930ea`, `4f1f03ad`, `b7f5d683`, …), which is why "19 tags in 55 days" reaches users as 19 updates rather than 19 downloads. `cf212c58` and `01709ee4` show the release-notes artifact feeding the Sparkle description and the GitHub body from one source.
- **Provenance: not a discovery.** `docs/roadmap.md:65-68` already states there is "no active Homebrew or Sparkle distribution surface", and `docs/TODO.md:31-33` explicitly withholds authorization to create or update Sparkle channels. The mirror corroborates the cost of that gap; it did not reveal it. What is new is the coupling: without an updater, every honesty fix in this report (F1, F2, F3, F9, Q3) reaches only users who happen to re-download, so cadence stops being a marketing metric and becomes a correctness-delivery metric.
- **Change.** Nothing before a build publishes — this is hard-gated behind row 0. When it unblocks: EdDSA keypair, `SU*` keys via the existing `$(MARKETING_VERSION)` token pattern in `macos/project.yml:198-209`, an appcast generated from `docs/release-notes/<version>.md` (UX-10) rather than hand-edited, and `SUAutomaticallyUpdate` **off** by default — Engram runs a write-owning helper process (`EngramService`) that AS does not, so a silent swap under a live socket needs its own design pass, not a copied plist.
- **Effort M. Impact high once publishing resumes, zero until then.** Do not start it before row 0 is decided.

---

## Where the mirror flatters us

Things Agent Sessions does that Engram should **not** copy, with reasons.

1. **The provider-auth quota cockpit.** `as-main/AgentSessions/CodexStatus/ClaudeUsageSourceManager.swift` (73 KB), seven credential rungs including Safari binarycookies and an interactive tmux probe, plus `claude_usage_capture.sh` (18.6 KB). Building it means shipping an OAuth/Keychain path and spawning another vendor's interactive CLI. AS needed four guards, `BROWSER=/usr/bin/true`, an opt-in default-off flag and a SIGKILL orphan sweep to make that safe. Engram already gets most of the user value with zero credentials: `usage_snapshots` carries `reset_at`/`limit_value`/`status` and `StartupUsageCollector` emits a 5h window with a derived reset clock. Their own `ClaudeWebCookieResolver.swift:19-26` documents a rung already dead on macOS 14/15; that is the maintenance tax made visible.
2. **Live $/h burn rate and its provisional-sample clamp.** The clamp is good engineering, but it exists only because AS renders a 5s-refreshing rate meter. Engram computes cost once per session from complete transcripts (`SessionCostPricing.computeCost` is a four-term sum); a repo-wide grep for `perSecond|perHour` returns zero. Adopting the clamp requires first building the meter, which is a P2-gated HUD.
3. **Codex side chats reconstructed from `~/.codex/sqlite` tracing logs** (`CodexSideChatLogReader.swift`, 899 lines, a 13-version persisted discovery cache, 50k candidate cap). Their own discovery predicate run against the real corpus on this machine finds `~/.codex/logs_2.sqlite` holding 136,699 rows across 85 threads and **zero** side-conversation threads, with `min(ts)..max(ts)` showing a rolling ~10.1-day retention window. Disqualifying for a memory layer regardless of Desktop usage.
4. **The NSTableView transcript rewrite** (`TranscriptBlockListView.swift`, 4,206 lines). Their controller-computed heights and `HeightKey`/`RenderKey` discipline exist to survive AppKit cell recycling. Engram's LazyVStack over stable per-message UUIDs cannot have that bug class, and the cache-keying lesson is already in CLAUDE.md ("don't use hashValue for cache keys") and implemented (`ContentSegmentParser.swift:14-27` derives ids from full content with an anti-collision comment).
5. **Schwartzian sort comparators and the `Table.id()` reorder-diff workaround.** Engram sorts in SQL: `SessionSort` raw values *are* `ORDER BY` fragments (`Database.swift:10-16`), and there is no `TableColumn` anywhere in `macos/`. The one real gap is a sort control on `SessionsPageView`, already tracked at `docs/roadmap.md:23`, and `TimelinePageView.swift:211` shows the correct pattern.
6. **Prebump** (drive 10 real vendor CLIs in a sandboxed `$HOME`). AS's own `b65aa748` records that a green prebump missed Claude 2.1.211's `mode` event because a one-shot `-p` run never emits interactive-only families; the real-corpus weekly scan caught it. Engram's polycli health pings already deposit fresh headless sessions for seven providers into the local corpus, so F5's fingerprinting gets the sample for free.
7. **App-inactive throttling.** Already audited and rejected with reasons in the 2026-06-19 idle-CPU pass (`CHANGELOG.md:2492-2536`), which deliberately kept the 5s health probe for crash-detection responsiveness.
8. **`reindexSessionMeta`-shaped scoped clears.** Deleting `file_index_state` rows is a no-op against `SwiftIndexer.swift:249-265`'s second skip layer, which re-stamps a fresh cache row without parsing.
9. **Tail-first cold paint** (see Q4).
10. **The repo-triage agent** — 18 commits on 2026-07-16 building `as-main/tools/triage/` (`gather.sh` → `run-agent.sh` → `reply.sh`, a launchd plist template, `policy.json`, an installer/uninstaller, and `tests/`), plus a blog post (`456497e2`). Its design rule is worth quoting: `as-main/tools/triage/README.md:9-12` — the agent is **tool-less**, "the data goes in the prompt as text… so attacker-controlled text in an issue body can't steer it into running shell, fetching URLs, or posting", with a blocking confinement acceptance test (`4d81b789`) and a hardened post path (`1ef9aae0`). **Do not build this.** It triages a public issue queue; Engram's issue tracker has zero issues and its eight open PRs are 100% Dependabot (UX-5), so the input does not exist. Revisit only after UX-5 gives the app a mouth and the queue is non-empty. **The adjacent question it raises is already answered internally, not by the mirror:** Engram's MCP tools return stored session and insight text straight to a calling model, which is indirect prompt injection by construction — filed and dispositioned eight days before this report as `SEC-L4`, accepted residual (`docs/reviews/2026-07-17-engram-security-audit.md:291`, `docs/reviews/2026-07-17-accepted-residuals.md:14`), with instruction-isolation wrappers named as a product design track. This report adds no new evidence there and should not be read as reopening it.

Sub-recommendations narrowed rather than adopted whole, listed at their items: structured MCP projection fields (F2), a shared absence-copy enum and a "configure limits" link (UX-4), the remote half of the price fetch (F8), CI perf-budget widening (Q1), the full typed remediation ladder (Q3), fresh-install-by-artifact-absence and onboarding default seeding (UX-2), an invariant-comment lint (Q6), a three-surface scan coordinator (F11), parity-fixture drift baselines and CI-hosted drift checks (F5), per-tool durations (UX-7), `site/index.html` in the hero scope (UX-11), `searchableTierSQL` for the health predicate (F3), and NSCache re-keying on the query string (UX-1).

### Where Engram is already ahead

- **Search availability during a rebuild.** `macos/EngramCoreWrite/Database/FTSRebuildPolicy.swift:37-64,:100-127,:130-146` builds into `sessions_fts_rebuild`, backfills anything the shadow missed, and refuses to swap while `eligibleSessionsMissingRebuildContent != 0`. AS documents the opposite in their own code: `as-main/AgentSessions/Indexing/DB.swift:388-394` records a measured ~149s window where a source's search hits go 500 -> 0 -> 500, with the honest note that "preserving the corpus saves reparse COST, not availability."
- **CI actually runs the tests.** `.github/workflows/test.yml:139-250` runs ~2,555 Swift logic tests across four schemes plus 1,387 vitest cases, with SHA-pinned actions, byte-exact fixture determinism, `xcodegen` drift detection, and a numeric perf budget (`scripts/ci/check-perf-results.py --max-average-seconds 0.100` against a committed 0.047 baseline). `as-main/.github/workflows/ci.yml` is 29 lines of `xcodebuild ... build` with `CODE_SIGNING_ALLOWED=NO` and no `xcodebuild test` anywhere. Their 1,761 tests run only on the maintainer's Mac, which is why they needed a QA stamp with a 24h TTL. Residual gap we own: UI regression is 62 test functions, of which 7 classes run pre-merge and the full suite only post-merge on main.
- **Incremental parse.** `SwiftIndexer.attemptTailIndexing` (`:351-414`) parses only the new tail, gated on `parsedOffset` + boundaryHash + inode + device, and `:626-643` chains a SHA256 content fingerprint so body rewrites at stable size/counts still invalidate. AS re-parses whole files.
- **Honest degradation is a typed contract.** `SemanticDegradeReason` names five causes (`SessionVectorSearchAvailability.swift:28-58`), and MCP *hard-errors* on an unavailable mode rather than silently keyword-falling-back; `docs/mcp-semantic-search-design-2026-07.md:187-189` records the reasoning ("agents treat soft warnings as success"). `SearchOutcome.failed` (`SearchPageView.swift:41-52`) exists specifically "so the UI doesn't read a down index as 'your data is missing'".
- **Release-shipping service telemetry.** A 200-span ring buffer with p50/p95/max/errorCount per IPC command, wired into every command (`EngramServiceCommandHandler.swift:100-115`) and surfaced in two in-app views. No equivalent in the mirror.
- **Machine-checked architectural invariants.** `docs/invariants.md` (13 entries: Statement / Enforced by / Verified by / Gate) bound to executable gates by `scripts/invariant-gates.json` + `check-invariants-ledger.sh`, whose argv validator rejects anything but `["bash","scripts/*.sh"]` so markdown can never become shell. `check-app-mcp-cli-direct-writes.sh` mechanically enforces a CLAUDE.md rule. AS's equivalent knowledge lives in file header comments.
- **Failure taxonomy and persistence.** A 15-case `ParserFailure` contract with a terminal-vs-retry policy, and `file_index_state` persisting `failure_kind` per file per source with an index. The data F5/F6 need already exists; only aggregation and rendering are missing.
- **Parser research depth.** 34 format references (codex.md 106 KB, claude-code.md 95 KB) each citing live corpus counts, repo fixtures, and both parsers, plus golden parity fixtures for 15 sources and a 9-category malformed taxonomy. AS's per-agent evidence is a matrix row.
- **Refusing to guess a price.** `longestDelimitedMatch` (`SessionCostPricing.swift:254-266`) rejects a following digit, so `gpt-5.6-sol` deliberately does *not* match `gpt-5`. AS's plain `hasPrefix` would price it at $1.25/$10 against their own bundled $5/$30, a 4x silent understatement. Our nil-instead-of-guess is more honest; it just needs a data path (F8).
- **Reduce Motion.** `macos/Engram/Components/MotionAware.swift:3-35` owns every animation; a repo-wide grep finds **0** raw `withAnimation` outside that file, with 29 downstream `reduceMotion` references and shimmer suppression in `SkeletonRow.swift:22-25`. No comparable centralization on their side.
- **Source status honesty (the surface, not the predicate).** `SourcePulseView.swift:319-348` renders a NOT DETECTED chip, `0 sessions`, the expected default path, and a live `PathExistsIndicator`; `:265-299` adds a STALE badge, a failed-index-job pill, and coverage percentages. AS has nothing comparable. F3 fixes the one wrong predicate underneath it.
- **The transcript volunteers uncomfortable truths.** `SessionDetailView.swift:251-266` states "Search covers loaded messages only." with a one-tap Load all; `:936-955` `copyAllTranscript` force-loads the remainder before writing the pasteboard; `MessageTypeChip.swift:19` renders `N+` instead of a false total.
- **Deletion runs as a program.** `docs/followups.md:200-419` documents an 11-PR feature-cut campaign (PRs #103-#113) with an orphan-tracer lens over settings keys, on-disk artifacts and stale comments, per-item KEEP lists with a stop-and-file-a-blocker gate, and one tombstone test per deleted surface; `AppSearchServiceCutoverScanTests.swift:1060-1088` even asserts stale comments were refreshed. AS does this by hand, per commit.
- **Backlog hygiene.** Three documented entry points (`docs/CONTRIBUTING.md:39-46`), one open TODO carrying goal/files/order/done-when/failure-handling/authorization-boundary, 12 explicitly decision-pending roadmap rows, and **one** TODO marker across 512 Swift files.
- **Idle CPU is a closed, measured question.** The 2026-06-19 audit (`CHANGELOG.md:2492-2536`) fixed four burn sources and recorded both processes at 0.0% CPU post-startup (`:2591`). *Unverified:* not re-measured at HEAD.

---

## Prioritized backlog

One row per surviving recommendation. **The ordering is a work sequence, not a value ranking.** It groups by category (agent-facing correctness → honesty of published numbers → cheap high-visibility fixes → structural programs → polish and distribution) and then by effort inside each group, which is why two of the highest-value items (22, 23) sit near the bottom. The seven highest-value items regardless of position are rows **0, 1, 2, 6, 18, 22, 23** (TL;DR #11).

**Structural note on the shape of this list.** All 35 engineering rows add or correct behaviour; **none removes a shipped user-facing surface.** The mirror's dominant motion in the same window was the opposite — Git Inspector deleted outright (`8049b542`, 2.1k LOC, commit body: "shipped feature-flagged in v2.5, off by default, unused in practice"), Compact and Full Cockpit retired in 4.6.4, three dead Preferences toggles dropped (`b5a5d3bb`), `CockpitView` (`f62456c8`), `UsageStripView` (`826d50a6`) and the double-click probe gesture (`2f7fea8f`) removed. Their stated rationale in 4.6.4 — surfaces that "duplicated what the main window already does better" — points at a question this report does not answer and should not answer without usage evidence: `Screen` declares **13 navigable screens plus Settings** (`macos/Engram/Models/Screen.swift:4-23`), including `repos` and `workGraph` (`macos/Engram/Views/MainWindowView.swift:113-116`, 567 lines under `Views/Workspace/`) — the closest analogue to what AS deleted. Treat that as a candidate for a *separate* usage-evidence pass, not as a recommendation here; Engram ships no in-app analytics, so today there is nothing to decide it on.

| # | Recommendation | Effort | Impact | Landing zone | Ref |
|---|---|---|---|---|---|
| 0 | **Decide whether to publish.** Owner decision, not engineering — the report names it as the root cause of the whole distribution section but never gave it a row. Rows 33, 34, 35 are hard-gated on it; rows 6 (CTA half), 17 and 18 derive most of their value from it | — | Highest | `docs/TODO.md:8-33` (authorization boundary), `docs/roadmap.md:65-68` | UX-11 |
| 1 | `get_context`/`search`: filter `superseded_by IS NULL`, emit insight ids | S | High | `MCPDatabase.swift:1959-1998,:1070-1080` | F1 |
| 2 | Source health: exclude skip from both numerator and denominator, add `healthReason` | S | Medium | `EngramServiceReadProvider.swift:1011-1017,:1842` | F3 |
| 3 | `get_insights`: derive `windowDays`, refuse below ~3 days | S | Medium | `MCPInsightsTool.swift:5-7` | F2 |
| 4 | Disclose unpriced cost rows, split by cause | S | Medium | `MCPDatabase.swift:231-238`, `EngramServiceReadProvider.swift:1140-1155` | F9 |
| 5 | Post `.restartService`; delete the false comment; add a poster test | S | Medium | `App.swift:151-158`, `HomeView.swift:255-274` | Q3 |
| 6 | Fix repo description/topics; delete the false file-watch README line | S | Medium | GitHub metadata, `README.md:117` | UX-3 |
| 7 | Onboarding window delegate + Windsurf probe path + helper path from `Bundle` | S | Medium | `App.swift:273,:288`, `OnboardingView.swift:228`, `SourcesSettingsSection.swift:544` | UX-2, F7 |
| 8 | `.user` -> `SegmentedMessageView` (one line) | S | Medium | `ColorBarMessageView.swift:195-199` | UX-1a |
| 9 | Hold last-good live sessions across a failed poll (3 sites) | S | Medium | `SourcePulseView.swift:120-127`, `PopoverView.swift:270-272`, `MenuBarController.swift:429-437` | Q2 |
| 10 | Hidden-type match count in the find bar | S | Medium-high | `SessionDetailView.swift:85-89,:155` | UX-1b |
| 11 | Suppress Resume for Claude workflow subagents | S | Medium | `EngramServiceReadProvider.swift:1364-1445`, `ExpandableSessionCard.swift:228-271` | F10 |
| 12 | Surface persisted `file_index_state.failure_kind` (service DTO + chip + MCP `stats`) | S | Medium | `EngramMigrations.swift:163-182` | F6 |
| 13 | Usage bar: limitless share renders as text, not a filled meter | S | Medium | `PopoverUsageSection.swift:274-336` | UX-4 |
| 14 | Local `~/.engram/prices.json` overlay with `adopt()` acceptance rule | S | Medium | `SessionCostPricing.swift:12,:112-118` | F8 |
| 15 | `git_head`/`git_dirty` injected pre-archive; `--require-ci-green` | S | Medium | `macos/project.yml:198-209`, `release-verify.sh` | Q5 |
| 16 | DEBUG `PerfSignpost` + stall monitor + 4 app-local spans | S | Medium-high | new `macos/Engram/Support/PerfSignpost.swift` | Q1 |
| 17 | Help menu: Report an Issue, Show Onboarding, Attach diagnostics | S | Low-med (High post-ship) | `MenuBarController.swift:504-560` | UX-5 |
| 18 | `docs/release-notes/<version>.md` + presence check in `validate-release-tag` | S setup, recurring | Medium | `.github/workflows/release.yml:26-35` | UX-10 |
| 19 | Accessibility labels on icon-only transcript controls (~15) | S | Low-medium | `TranscriptToolbar.swift`, `MessageTypeChip.swift` | UX-8 |
| 20 | Dated update block on `docs/competitive-relaunch-2026-06.md` (27 tools, plugin shipped) | XS | Low | that file | UX-11 |
| 21 | Invariant back-references in incident comments (CLAUDE.md bullet) | S | Low | CLAUDE.md | Q6 |
| 22 | Codex native parent signals + forced re-parse migration | M | High | `CodexAdapter.swift:623`, `StartupBackfills.swift:1621-1631` | F4 |
| 23 | Adapter format-drift program (fingerprint, freshness gate, matrix, drift tests) | M | High | new `scripts/check-adapter-format-drift.ts`, `docs/session-formats/` | F5 |
| 24 | MCP activation card on HomeView + onboarding step 5 | M | Medium-high | `HomeView.swift`, `OnboardingView.swift` | F7 |
| 25 | `scanNow` service command (MCP-reachable) + currency-aware read | M | Medium | `EngramServiceCommandHandler.swift:1483-1495` | F11 |
| 26 | Find-bar highlight on the rendered AttributedString | M | Medium | `ColorBarMessageView.swift:162-170` | UX-1a |
| 27 | Byte-offset transcript cursor + append-only `rebuildIndexed` | M | Medium | `CodexAdapter.swift:420-437`, `SessionDetailView.swift:1005-1040` | Q4 |
| 28 | Verify-MCP-setup rung ladder in Settings | M | Medium | `SourcesSettingsSection.swift:599`, `EngramCLIContextCommand.swift:129-168` | UX-6 |
| 29 | Banner/empty-state action sweep + `ServiceErrorPresenter` routing | M | Medium | `AlertBanner.swift:6`, `EmptyState.swift:8` (45 sites) | UX-9 |
| 30 | Per-turn duration chip (turns only) | M | Medium | `MessageParser.swift:11-18`, `ColorBarMessageView` roleHeader | UX-7 |
| 31 | Dynamic Type ramp (`@ScaledMetric` / semantic fonts) | M | Low-medium | `SidebarView.swift:21,:46`, transcript body | UX-8 |
| 32 | Claude workflow-nested subagents (`subagents/workflows/`) | M | Low-medium | `ClaudeCodeAdapter.swift:112-119` | F12 |
| 33 | Hero asset: terminal recording + README `<picture>` pairs | M | Medium | `ScreenshotCapture.swift`, new `docs/assets/` | UX-11 |
| 34 | Public product page + SEO guides from `docs/session-formats/` | L | Medium | new `site/` or `docs/` Pages | UX-11 |
| 35 | In-app updater (Sparkle 2 + appcast generated from the release notes, auto-install default-off) | M | High post-ship, zero before | `macos/Engram/Info.plist`, `macos/project.yml:198-209` | UX-12 |

Rows 33-35 are hard-gated on row 0. Row 18 should land in the same PR sequence as the first publish, and row 35 consumes its output. **Filed, deliberately not scheduled:** grandchild sessions missing from the list hierarchy (F12) — real, but measured at 6 non-skip rows and recoverable through the detail view.

---

## Method and limits

**What was done.** Three section drafts (features, implementation quality, UI/UX) were produced in parallel against the v4.6.4 snapshot and the Engram working tree, then assembled here with a deduplication and contradiction pass. A final completeness pass re-read all 19 changelog entries and all 400 non-merge commits in the window looking for untouched areas, and re-verified the load-bearing Engram claims; its additions (the commit-area breakdown after the release table, F12's grandchild bullet, "Where the mirror flatters us" #10, UX-12, backlog row 0 and row 35, the structural note on the shape of the backlog) and its one correction (analytics) are marked at their locations.

**Verified in this assembly pass** (re-run against source, not carried from drafts):
- Source health measured on the live `~/.engram/index.sqlite` by reproducing the provider's own two SQL statements: **18 of 21 sources** report searchable < total, not "all 21". claude-code is 1,180/18,370 sessions. **This corrected a contradiction:** one draft cited message-level figures (228,070/245,260) for a session-level predicate.
- `restartService`: repo-wide grep returns exactly 5 lines and zero posters.
- `MCPInsightsTool.swift:5-7`: the `/ 7.0` divisor with an arbitrary `since` is verbatim.
- `searchInsightsFTS` (`MCPDatabase.swift:1959-1998`): neither branch filters `superseded_by`.
- `CodexAdapter.swift:623`: `parentSessionId: nil` is verbatim.
- `ColorBarMessageView.swift:162-170`: the `if searchText.isEmpty` render switch is verbatim.
- `grep -rni mcp macos/Engram/Onboarding/` = 0; `grep -rn "dynamicTypeSize\|ScaledMetric" macos/Engram` = 0.
- Repo description and topics via `gh repo view --json description,repositoryTopics,homepageUrl`.
- Agent Sessions version list and dates via `/usr/bin/git tag --sort=-creatordate` and `docs/CHANGELOG.md` headings: 19 tags, v3.8.1 (2026-05-27) through v4.6.4 (2026-07-21). Engram side re-checked: `gh release list` shows v1.0.3 (2026-05-07) as Latest with no v1.0.4 release; `git tag` shows `v1.0.4` exists; `git rev-list --count v1.0.3..HEAD` = **1341**.
- Sparkle absence (UX-12): `macos/Engram/Info.plist` read in full, 27 keys, no `SU*`; greps for `Sparkle`, `checkForUpdates`, `SUUpdater`, `updateCheck` across `macos/` = 0. AS side read verbatim at `AgentSessions/Info.plist:33-45`.
- Grandchild count (F12): the two SQL statements quoted in that item, run against `~/.engram/index.sqlite` — 130 total, 124 skip-tier, 6 non-skip; 230 parents over the 20-child page size, max 2,017 children.
- Commit-area breakdown after the release table: `v3.8..origin/main --no-merges` = 400 commits; case-insensitive subject matches — triage 18, blog/site/seo/marketing/content 18, handover 22, agent-support/agent-watch 10.
- Engram screen count: `Screen.swift:4-23` enumerates 13 content cases plus `settings`.

**Corrected in this critique pass.** An earlier version of this section said "no analytics exist in either repo." That is false for the mirror: Agent Sessions added cookieless GoatCounter on 2026-07-17 (`252671cf`), present at `as-main/docs/index.html:403`, `as-main/docs/_layouts/blog.html:13`, and every `as-main/docs/guides/*.html:22`. Engram has none, in the app or on any public surface — which is why the row-0 note above says there is nothing to decide surface-area questions on.

**Not verified.** Neither app was built or run. All behavioral claims are read from source. Idle CPU and launch latency were not re-measured at HEAD. Whether the published v1.0.3 zip is actually notarized was not checked. Whether AS's SEO guides rank or convert is still unknown: GoatCounter records page views, but no funnel or download-attribution instrumentation exists in either repo, and their counter data is not public. Live-corpus figures carried forward from the section drafts and **not** independently re-measured in this pass: 1,929 unpriced cost rows, 389 mismatched Codex suggestions, 14,991 Claude subagent rows, 635/637/481 Codex spawn-signal counts, ~31,400 workflow transcripts, the `logs_2.sqlite` side-chat query, and the 45 unremediated banner sites. Each cites a reproducible query or grep in its item; all were measured on 2026-07-24 on an N=1 Codex-CLI-heavy machine and will drift.

**Killed by the skeptic pass.** Ten whole-feature borrowings were rejected outright (listed under "Where the mirror flatters us"): the provider-auth quota cockpit, the live $/h burn meter and its clamp, Codex side-chat log reconstruction, the NSTableView transcript rewrite, Schwartzian sort comparators and the `Table.id()` workaround, sandboxed prebump drivers, app-inactive throttling, `reindexSessionMeta`-shaped scoped clears, tail-first cold paint, and the repo-triage agent. A further ~15 sub-recommendations were killed or narrowed inside surviving items; they are enumerated at the end of that section. 35 engineering recommendations survive, behind one row-0 owner decision; one further verified finding (F12 grandchildren) is filed without a row.

**Provenance honesty.** Three high-ranked items are Engram defects the mirror exercise surfaced rather than Agent Sessions transfers, and are flagged as such at their entries: F1 (`get_context` supersede, AS's handover skill supplies only the principle), F9 (unpriced disclosure, AS filters silently and never discloses either; the recommendation is our own 2026-06-10 audit's unshipped half), and UX-1a (found internally on 2026-06-14 and deferred). Two items correct earlier internal false closures: Q3 was predicted verbatim at `docs/reviews/alignment-design-2026-06-14.md:1055` and then declared resolved, and UX-11's competitive doc has drifted in two facts.

---

## Follow-up specs

Four of the seven "do first" rows were written up as design docs against
`docs/templates/design-doc.md` on 2026-07-24, then reconciled in a single
integration pass. Each spec re-verified the mirror's `path:line` anchors rather
than copying them, and each records where the mirror was wrong.

| Row | Spec | One line |
|---|---|---|
| 1 | `docs/insight-supersede-filter-design-2026-07.md` | Probe-gated `AND superseded_by IS NULL` in `searchInsightsFTS` + `listInsightsByWing`, closing the leak on `get_context`, `search`, `get_memory` and `resources/list`; adds ledger invariant 14. |
| 2 | `docs/source-health-predicate-design-2026-07.md` | Source health verdict and `Search N%` move to an index-eligible (non-`skip`) denominator, plus a `healthReason` string on the DTO and a badge tooltip; orange badges go 18 → 8, not 18 → 0. |
| 22 | `docs/codex-native-parentage-design-2026-07.md` | New version-gated startup backfill `backfillCodexNativeParents` reads the vendor-stamped Codex spawn parent off the rollout head — no adapter change, no forced re-parse — and clears the wrong suggestions on exactly the rows it links. |
| 23 | `docs/adapter-format-drift-design-2026-07.md` | Local-only fingerprint of real sessions per format against a committed baseline, a freshness gate keyed on the embedded vendor version, a support matrix, and Swift drift guards for `world_state` + Claude Code lifecycle records. |

### Implementation sequence

Land in this order. Only one dependency is hard; the rest are line-level merge
serialization on shared files.

1. **Row 1** — MCP-only read path. Touches no file any other spec touches except
   `docs/invariants.md`, where it *appends* a new entry 14 and amends nothing,
   so it has zero merge surface. Its slices are internally ordered: slice 3
   (ledger + `docs/mcp-tools.md`) must not land before slice 2, or the published
   claim outruns the fix.
2. **Row 2** — service read path. Amends `docs/invariants.md:23` (entry 3's
   `Verified by` list). Slices 1 and 2 should reach the same release; branch 5
   (`empty` for 100%-skip sources) must stay inside slice 1 or slice 1 alone is
   a regression.
3. **Row 22** — writer-side startup backfill. Amends `docs/invariants.md`
   entries 2, 3, 9, 10 — including the same `:23` line row 2 edits, so it rebases
   onto row 2's amendment (the two additions are a union). Slice 4 also flips
   `docs/session-formats/codex.md:718` **and** its Chinese mirror
   `codex.zh.md:692`.
4. **Row 23** — dev tooling + adapter counter. Adds nothing to the ledger.

**The one hard dependency: 22 → 23, and it is documentary, not structural.**
Row 23's `--accept` path stamps `docs/session-formats/codex.md` and `codex.zh.md`
as freshly researched; row 22 slice 4 rewrites the "NOT consumed by Engram" claim
inside those same files. Running the first Codex accept before row 22 slice 4
lands produces a doc carrying a 2026-07-24 verification stamp beside a claim that
is about to become false. Land row 22 slice 4 first, or re-run the Codex accept
afterwards.

**Row 23's baseline capture is *not* ordered relative to row 22.** The
fingerprint is taken over the vendor's on-disk key surface under
`~/.codex/sessions`. Row 22 explicitly rejects the adapter route and changes no
parser, no on-disk file, and no record shape — it adds a startup backfill that
reads rollout heads and writes `sessions.parent_session_id`. The observed
bucket/key set is therefore identical before and after row 22, and a baseline
seeded early does not need to be re-taken.

Rows 1 and 2 are mutually independent (different processes: `EngramMCP` vs
`EngramService`) and can be developed in parallel; only their `docs/invariants.md`
commits need serializing.

**Rows 6 and 18 were deliberately deferred by the owner** — publishing the repo
description/README fix and the `docs/release-notes/<version>.md` presence check
both derive most of their value from row 0 (the publication decision), which
remains open, so neither was specified in this pass.
