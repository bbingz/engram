# Release Readiness Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring the current branch to a releasable state by closing the highest-confidence blockers from review: release hygiene / failing quality gates, stale docs, and `todayParents` startup inconsistency.

**Architecture:** Keep the current parent-linking / Swift path-fallback changes intact. Apply narrowly scoped fixes in three independent tracks: quality-gate cleanup, documentation sync, and daemon event timing. Preserve current behavior where tests already prove it, and use targeted regression tests for any behavior changes.

**Tech Stack:** TypeScript (Node 20, Vitest, Biome, Knip), Swift 5.9 / SwiftUI / XCTest, XcodeGen.

---

## File Map

- `src/daemon.ts` — daemon startup sequencing and emitted event payloads
- `tests/core/*.test.ts` — daemon / session-parent regression coverage for startup event timing
- `macos/Engram/Components/Theme.swift` — local-time formatting helper used by Observability views
- `macos/EngramTests/ThemeTests.swift` — XCTest coverage for timestamp formatting behavior
- `.tmp-parent-detection.mjs` — local temporary script to remove from release branch if not required
- `tests/fixtures/antigravity/cache/*.jsonl` — local cache artifacts to exclude from release diff unless intentionally committed
- `README.md` — user-facing product overview, supported sources, API summary, test/build numbers
- `CHANGELOG.md` — release metadata and changed/fixed notes
- `CLAUDE.md` — project operating guidance and current architecture snapshot
- `docs/mcp-tools.md` — MCP tool reference, including `save_insight` defaults
- `docs/PRIVACY.md` / `docs/SECURITY.md` — network/security behavior and startup constraints

---

### Task 1: Release hygiene + quality gate cleanup

**Files:**
- Modify: `.gitignore` (only if needed for local cache/temp files)
- Modify: `macos/EngramTests/ThemeTests.swift` and/or `macos/Engram/Components/Theme.swift`
- Investigate: `knip.json`, `src/core/bootstrap.ts`, `src/tools/save_insight.ts` if choosing to resolve current knip findings
- Remove or ignore: `.tmp-parent-detection.mjs`, `tests/fixtures/antigravity/cache/*.jsonl`

- [ ] Reproduce current gate failures exactly:
  - `npm run lint`
  - `npm run knip`
  - `npm run test:coverage`
  - `cd macos && xcodegen generate && xcodebuild test -project Engram.xcodeproj -scheme Engram -only-testing:EngramTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`
- [ ] For Swift unit failure, write/adjust the failing XCTest first so expected timestamp behavior is explicit, then make the minimal code or test correction.
- [ ] Resolve quality-gate blockers that are in scope for this branch:
  - eliminate release-noise files from the diff
  - fix `ThemeTests` local-time expectation mismatch
  - decide whether to fix or intentionally defer knip unused exports with evidence
- [ ] Verify:
  - `git status --short`
  - `npm run test:coverage`
  - `npm run knip`
  - `cd macos && xcodebuild test -project Engram.xcodeproj -scheme Engram -only-testing:EngramTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`

### Task 2: Documentation synchronization

**Files:**
- Modify: `README.md`
- Modify: `CHANGELOG.md`
- Modify: `CLAUDE.md`
- Modify: `docs/mcp-tools.md`
- Modify: `docs/PRIVACY.md`
- Modify: `docs/SECURITY.md`

- [ ] Update all stale test/build counts to the current verified numbers.
- [ ] Correct `save_insight` documentation to default importance `5` everywhere.
- [ ] Sync README/API/security wording with current code behavior:
  - supported source paths
  - current Web/API capabilities
  - `httpAllowCIDR` startup refusal semantics
  - parent-child linking / today badge summary where relevant
- [ ] Keep changes documentation-only; do not drift code to match old docs.
- [ ] Verify with targeted searches:
  - `rg -n "909 tests|893 tests|default 3|httpAllowCIDR|todayParents|save_insight" README.md CHANGELOG.md CLAUDE.md docs`

### Task 3: Fix `todayParents` startup timing + regressions

**Files:**
- Modify: `src/daemon.ts`
- Test: relevant daemon/session timing test under `tests/core/` or `tests/integration/`
- Optional modify: `macos/Engram/Core/IndexerProcess.swift` only if event handling contract changes

- [ ] Write a failing regression test first proving that the first user-visible count is computed after parent-link/tier backfill, not before.
- [ ] Implement the minimal daemon change:
  - either move the initial `todayParents` emission after startup backfills
  - or emit a second authoritative event immediately after backfills complete
- [ ] Keep event payloads backwards-compatible unless a test proves UI changes are needed.
- [ ] Verify:
  - targeted test for the startup timing bug
  - `npm run build`
  - `npm test`

---

## Final verification

Run before completion:

```bash
git status --short --branch
npm run lint
npm run build
npm run test:coverage
npm run knip
cd macos && xcodegen generate
cd macos && xcodebuild test -project Engram.xcodeproj -scheme Engram -only-testing:EngramTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

## Success criteria

- No accidental temp/cache files remain in the intended release diff
- Documentation matches current code and verified numbers
- `todayParents` no longer reports a stale startup value
- TypeScript and Swift verification commands are green, or any deliberate deferrals are explicitly documented with evidence
