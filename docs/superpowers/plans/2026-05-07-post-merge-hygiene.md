# Post-Merge Hygiene Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the remaining inspector follow-ups verifiable without expanding runtime scope.

**Architecture:** Keep fixture determinism in the generator and CI, not in tests that consume the fixture. Keep signing portability as documentation and inline guidance, preserving current Xcode signing behavior.

**Tech Stack:** TypeScript fixture generator, GitHub Actions, XcodeGen project configuration, Markdown docs.

---

## Files

- Modify `.github/workflows/test.yml`: extend fixture determinism gate.
- Modify `scripts/gen-mcp-contract-fixtures.ts`: isolate `save_insight` golden DB mutation.
- Modify `macos/project.yml`: add fork override guidance near `EngramTests` signing.
- Modify `README.md`: document local hosted Swift test signing.
- Modify `docs/SECURITY.md`: clarify ad-hoc vs hosted-test signing.
- Create `docs/superpowers/specs/2026-05-07-post-merge-hygiene-design.md`.
- Create `docs/superpowers/plans/2026-05-07-post-merge-hygiene.md`.

## Tasks

### Task 1: Stabilize MCP Contract Fixture Generation

**Files:**

- Modify: `scripts/gen-mcp-contract-fixtures.ts`
- Generated baseline: `tests/fixtures/mcp-contract.sqlite`
- Generated baseline: `tests/fixtures/mcp-golden/initialize.result.json`
- Generated baseline: `tests/fixtures/mcp-golden/list_sessions.engram.json`

- [ ] Add `buildSaveInsightGolden()` that creates a temporary `Database`, calls `handleSaveInsight()` there, normalizes the UUID in the returned result, and deletes the temporary DB.
- [ ] Replace the existing `save_insight.text_only` golden entry so it calls `buildSaveInsightGolden()` instead of mutating the shared `db`.
- [ ] Seed `project_aliases.created_at` with fixed timestamps instead of SQLite `datetime('now')`.
- [ ] Store the transcript fixture `file_path` as `tests/fixtures/mcp-runtime/transcripts/rollout-mcp-transcript-01.jsonl` instead of an absolute checkout path.
- [ ] Generate `initialize.result.json` from the Swift MCP runtime instructions so Swift executable parity remains byte-for-byte.
- [ ] Resolve relative transcript fixture paths in Swift MCP using the fixture DB location.
- [ ] Include `origin` in Swift MCP `list_sessions` output to match the generated contract.
- [ ] Run `npm run generate:mcp-contract-fixtures`.
- [ ] Run `npm run generate:mcp-contract-fixtures` again.
- [ ] Confirm `git diff --exit-code tests/fixtures/mcp-contract.sqlite tests/fixtures/mcp-golden tests/fixtures/mcp-runtime` passes after the refreshed baseline is committed.

### Task 2: Add CI Gate for MCP Contract Fixture Determinism

**Files:**

- Modify: `.github/workflows/test.yml`

- [ ] In the `fixture-check` job, after the existing `test-index.sqlite` diff, assert `tests/fixtures/mcp-contract.sqlite` exists.
- [ ] Run `npm run generate:mcp-contract-fixtures`.
- [ ] Diff `tests/fixtures/mcp-contract.sqlite`, `tests/fixtures/mcp-golden`, and `tests/fixtures/mcp-runtime`.
- [ ] Keep the existing `test-fixtures/test-index.sqlite` gate unchanged.

### Task 3: Document Signing Portability

**Files:**

- Modify: `macos/project.yml`
- Modify: `README.md`
- Modify: `docs/SECURITY.md`

- [ ] Add an inline comment near `EngramTests` signing explaining forks must mirror their host app team or override `DEVELOPMENT_TEAM`.
- [ ] Add a README section under source installation explaining why hosted Swift tests need matching signing.
- [ ] Clarify in security docs that ad-hoc/disabled signing is fine for CI smoke builds, while hosted XCTest bundles may need matching Apple Development signing.
- [ ] Do not change `DEVELOPMENT_TEAM`, `CODE_SIGN_IDENTITY`, or app entitlements.

### Task 4: Verify and Ship

**Files:**

- Modify as needed from Tasks 1-3.

- [ ] Run `npm run build`.
- [ ] Run `npm run lint`.
- [ ] Run `npx tsx scripts/generate-test-fixtures.ts` and `git diff --exit-code test-fixtures/test-index.sqlite`.
- [ ] Run `npm run generate:mcp-contract-fixtures` twice and confirm the second run is clean for MCP fixtures.
- [ ] Run `cd macos && xcodegen generate` and confirm generated project diff is expected.
- [ ] Run a focused hosted Swift test selector for `EngramTests/ThemeTests`.
- [ ] Commit the changes and push to the PR branch.
