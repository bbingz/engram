# Project Move Gemini/iFlow Compatibility Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make project_move migrate Gemini CLI and iFlow grouped project directories using observed on-disk metadata instead of only theoretical source-path encoding.

**Status (2026-06-06):** Plan reviewed by a subagent before implementation. Current `main` already contained the Gemini slug/projects.json and observed iFlow directory production behavior; this branch closes the plan-review gaps by adding explicit dry-run parity tests and recording the scope. OpenCode SQLite remains intentionally separate.

**Architecture:** Keep this PR focused on two grouped-source fixes. Gemini CLI uses a slug under `~/.gemini/tmp/<slug>` and `~/.gemini/projects.json`; iFlow can contain historical grouped dirs whose basename differs from `encodeIflow(src)`, so the orchestrator must identify old grouped dirs from structured `cwd` records before falling back to encoded names. OpenCode SQLite directory rewrites are intentionally excluded for a separate PR.

**Tech Stack:** TypeScript/Vitest, Swift/XCTest, SQLite-free file fixtures.

---

## Files

- Modify: `src/core/project-move/sources.ts`
- Modify: `src/core/project-move/gemini-projects-json.ts`
- Modify: `src/core/project-move/orchestrator.ts`
- Modify: `tests/core/project-move/sources.test.ts`
- Modify: `tests/core/project-move/gemini-projects-json.test.ts`
- Modify: `tests/core/project-move/orchestrator.integration.test.ts`
- Modify: `macos/EngramCoreWrite/ProjectMove/Sources.swift`
- Modify: `macos/EngramCoreWrite/ProjectMove/GeminiProjectsJSON.swift`
- Modify: `macos/EngramCoreWrite/ProjectMove/Orchestrator.swift`
- Modify: `macos/EngramCoreTests/ProjectMove/SessionSourcesTests.swift`
- Modify: `macos/EngramCoreTests/ProjectMove/GeminiProjectsJSONTests.swift`
- Modify: `macos/EngramCoreTests/ProjectMove/OrchestratorTests.swift`
- Modify: `CHANGELOG.md`
- Modify: `.memory`

## Task 1: Gemini Slug Encoding

- [x] Add tests proving Gemini project names use lowercase basename slugs with `_` converted to `-` and wrapping dashes stripped.
- [x] Add TS and Swift projects.json tests proving new Gemini entries use the slug rule rather than raw basename.
- [x] Verify RED with `npx vitest run tests/core/project-move/sources.test.ts tests/core/project-move/gemini-projects-json.test.ts` and the targeted Swift `SessionSourcesTests` / `GeminiProjectsJSONTests`.
- [x] Add `encodeGemini()` in TS and `SessionSources.encodeGemini()` in Swift; wire Gemini roots and projects.json updates through the slug rule.
- [x] Verify GREEN with the same focused tests.

## Task 2: Observed Grouped Dirs From Structured `cwd`

- [x] Add TS and Swift orchestrator tests where Gemini projects.json points to a custom old slug and iFlow history lives in a directory whose basename differs from `encodeIflow(src)`.
- [x] Add TS and Swift dry-run tests proving custom Gemini old slugs and observed iFlow dirs appear in `renamedDirs` without filesystem side effects.
- [x] Add a negative iFlow test proving a literal mention of the old path does not rename an unrelated dir unless a structured `cwd` equals the source path.
- [x] Verify RED with targeted TS and Swift orchestrator tests.
- [x] Add bounded JSON-line `cwd` inspection in the orchestrators, using observed grouped dirs before encoded fallback and detecting duplicate target plans before filesystem side effects.
- [x] Verify GREEN with targeted TS and Swift project-move test suites.

## Task 3: Closeout

- [ ] Run TS focused tests:
  `npx vitest run tests/core/project-move/sources.test.ts tests/core/project-move/gemini-projects-json.test.ts tests/core/project-move/orchestrator.integration.test.ts tests/core/project-move/review.test.ts tests/tools/project-mcp.test.ts`.
- [ ] Run Swift focused tests:
  `xcodebuild test -project macos/Engram.xcodeproj -scheme EngramCoreTests -destination 'platform=macOS' -only-testing:EngramCoreTests/SessionSourcesTests -only-testing:EngramCoreTests/GeminiProjectsJSONTests -only-testing:EngramCoreTests/OrchestratorTests CODE_SIGNING_ALLOWED=NO`.
- [ ] Run `npm run typecheck:test`, `npx biome check` on touched TS files, and `git diff --check`.
- [ ] Update `CHANGELOG.md` and `.memory` with exact verification evidence and residual OpenCode follow-up.
- [ ] Request subagent code review before PR.
- [ ] Push branch, open PR, wait for CI, then merge when green.
