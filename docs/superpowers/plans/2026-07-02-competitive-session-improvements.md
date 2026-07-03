# Competitive Session Improvements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the approved competitive session improvements without turning Engram into a chat assistant or dashboard clone.

**Status:** Completed in branch `codex-provider-audit-remediation` on 2026-07-02.

**Architecture:** Keep shipped behavior in the Swift app, EngramService, EngramMCP, and shared Swift modules. Use TypeScript only for repository checks, fixture checks, and docs/runtime verifiers. Every new app write remains service-gated. Competitive gaps begin as read-only detection, labels, filters, and diagnostics.

**Tech Stack:** Swift 5.9, SwiftUI, GRDB, EngramService IPC, native EngramMCP stdio, Vitest docs checks, existing Xcode test schemes.

**Execution choice:** Execute inline in the current Codex session on branch `codex-provider-audit-remediation`. Do not dispatch subagents because the phases share UI, docs, and verification state.

---

## Phase Gates

Each phase names the owner, decision gate, and verifier before product work starts.

| Phase | Owner | Decision gate | Verifier |
| --- | --- | --- | --- |
| Phase 1 runtime truth | MCP/docs owner | Source count comes from `SourceName`; MCP tool count comes from the golden `tools/list` contract; disabled features are explicit: keyword-only search, no live sessions MCP, no peer sync, no default quota network. | `npm run check:runtime-capabilities`; `npm test -- tests/docs/runtime-capabilities.test.ts tests/docs/mcp-tools.test.ts`; MCP executable tool-list test if registry changes. |
| Phase 2 taxonomy | Swift UI owner | Use existing fields first: `agent_role`, `parent_session_id`, `suggested_parent_id`, `hidden_at`, `tier`, child counts, and path heuristics. `side` remains unsupported unless fixtures prove a stable field. | Focused Swift taxonomy tests; app build for touched UI. |
| Phase 3 continuity | Swift UI owner + service/data owner | Projects owns alias and migration-state visibility; Settings may link to it. Mutating project actions remain service-gated and confirmable. | Focused Swift model/UI tests or app build; privacy docs check. |
| Phase 4 usage/cost | Swift UI owner + QA/review owner | Use local `usage_events`, `session_costs`, model/tool/file activity, and indexed freshness only. No provider credentials or provider-network calls. | Focused Swift read/UI tests or app build; privacy docs check. |
| Phase 5 coverage/performance | QA/review owner | Codex side-chat and archived-session gaps are represented as read-only tests or documented unsupported cases. List rows must use indexed lightweight state, not full transcript parsing. | Fixture/docs tests; targeted Swift performance/read tests where available; manual audit notes. |
| Phase 6 polish/accessibility | Swift UI owner + QA/review owner | Polish only existing screens and new controls from phases 2-4. No Ask Engram, chat Q&A, card-as-answer, or LLM answer surface. | App build; accessibility label/static checks where available; `git diff --check`. |

Negative gate for every phase: reject any Ask Engram, chat Q&A, card-as-answer, LLM-generated answer UX, product Node runtime path, implicit provider network call, or direct app/MCP SQLite write path.

---

### Task 0: SPEC Restore And Plan Baseline

**Files:**
- Create: `docs/superpowers/specs/2026-07-02-competitive-session-improvements-design.md`
- Create: `docs/superpowers/plans/2026-07-02-competitive-session-improvements.md`

- [x] Restore the reviewed SPEC from durable session evidence.
- [x] Add this plan with owners, verifiers, and decision gates for every phase.
- [x] Confirm the SPEC non-goals remain explicit.

### Task 1: Runtime Capability Truth And Positioning

**Files:**
- Create: `scripts/check-runtime-capabilities.ts`
- Create: `tests/docs/runtime-capabilities.test.ts`
- Modify: `package.json`
- Modify: `README.md`
- Modify: `docs/mcp-tools.md`
- Modify: `macos/EngramMCP/Core/MCPStdioServer.swift`

- [x] Write RED docs/runtime tests proving README, MCP docs, and MCP instructions drift from runtime source/tool truth.
- [x] Add a deterministic runtime capability checker that derives source names from Swift `SourceName` and MCP tool names from the golden tool contract.
- [x] Update README and MCP docs to describe the same source/tool counts, keyword-only search degradation, and MCP-first positioning.
- [x] Document every tool in the golden MCP contract, including `get_rules`.
- [x] Update MCP stdio instructions so the assistant-facing instructions do not repeat stale source counts.
- [x] Run the runtime checker and targeted docs tests.

### Task 2: Session Taxonomy, Badges, And Filters

**Files:**
- Create: `macos/Engram/Models/SessionTaxonomy.swift`
- Test: `macos/EngramTests/SessionTaxonomyTests.swift`
- Modify: `macos/Engram/Components/ExpandableSessionCard.swift`
- Modify: `macos/Engram/Views/Pages/SessionsPageView.swift`
- Modify: `macos/Engram/Views/Pages/SearchPageView.swift`
- Modify: `macos/Engram/Views/Pages/TimelinePageView.swift`

- [x] Write RED taxonomy tests for `subagent`, `workflow`, `archived`, `orphan`, `suggested parent`, and unsupported `side`.
- [x] Implement a pure classifier over existing session fields and known child counts.
- [x] Add stable badges where sessions are already rendered.
- [x] Add filters to Sessions, Search, and Timeline without weakening parent/child grouping.
- [x] Keep suggested-parent copy advisory, not confirmed.
- [x] Run focused Swift tests and app build for touched UI.

### Task 3: Project Continuity Surfaces

**Files:**
- Modify/create focused files under `macos/Engram/Views/Pages/` and `macos/Engram/Models/` as needed.
- Modify EngramService client/read models only if an existing alias or migration-state read is not available.
- Modify: `docs/PRIVACY.md` if user-visible behavior needs clarification.

- [x] Inspect current project alias, move, archive, recover, and undo read paths.
- [x] Add a native read surface for aliases and project-continuity state under Projects.
- [x] Route any mutation through existing service commands and add explicit confirmation.
- [x] Show migration/recovery state without requiring users to read logs or MCP output.
- [x] Run focused Swift tests or app build plus privacy docs check.

### Task 4: Usage, Cost, And Optional Runway Panels

**Files:**
- Modify/create focused files under `macos/Engram/Views/Pages/`, `macos/Engram/Models/`, and read facades as needed.
- Modify: `docs/PRIVACY.md` if quota/runway wording changes.

- [x] Inspect current cost, usage, model, tool, file, and freshness read paths.
- [x] Add focused local usage/cost panels from indexed data only.
- [x] Add quota/runway empty states that state data source and freshness, without reading credentials.
- [x] Avoid provider-network calls and automatic credential discovery.
- [x] Run focused Swift tests or app build plus privacy docs check.

### Task 5: Competitive Coverage And Performance Audit

**Files:**
- Modify or add fixtures/tests under `tests/` and Swift fixture resources as appropriate.
- Modify: docs describing unsupported competitive shapes where no stable field exists.

- [x] Add or update read-only fixture coverage for Codex side-chat and archived-session shapes.
- [x] Represent unsupported cases explicitly when source data does not provide a stable mapping.
- [x] Audit Sessions, Timeline, and Search list rows for full-transcript parsing.
- [x] Add regression tests or manual verification notes for large-history expectations.
- [x] Confirm restore/write-back remains out of scope.

### Task 6: Focused Polish, Accessibility, And Durable Closeout

**Files:**
- Modify focused SwiftUI files touched by phases 2-4.
- Modify: `.memory/`
- Modify: `CHANGELOG.md`

- [x] Add accessible labels, empty/loading/error states, and consistent status-badge copy for new controls.
- [x] Run final targeted verification and `git diff --check`.
- [x] Record changed behavior, verification, and remaining risks in `.memory` and `CHANGELOG.md`.
