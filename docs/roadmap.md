# Engram Roadmap

Canonical pending-work list. Supersedes the per-PR gap notes in
`tasks/issues.md`, which were written 2026-04-29 against the Node-era spec.

**2026-05-23 update:** every open item below was driven to resolution via TDD
against the **Swift product** (`macos/`). New Swift tests + a fixture-generator
parity update accompany each behavior change. TypeScript under `src/` remains
dev/reference only.

## Status table

| Area | Item | Verdict |
|------|------|---------|
| Workspace | `git_repos` never populated — Repos page dormant | **DONE** — `RepoDiscovery` populates it; wired into the service recent-scan |
| Indexing | Auto-generate title on new-session index (`generated_title` was NULL) | **DONE** — `SessionSnapshotWriter` derives it at index time |
| Search | `SearchView` semantic mode = false promise (no sqlite-vec) | **DONE** — `SearchMode.availableModes` restricts to keyword unless embeddings available |
| Search | `GlobalSearchOverlay` hardcoded "hybrid" | **DONE** — now requests keyword |
| Transcript | No "Copy entire conversation" in message context menu | **DONE** — added, backed by `TranscriptText.conversationText` |
| Transcript | Tool rows showed generic `TOOLS #N` | **DONE** — `ColorBarMessageView.displayLabel` surfaces `TOOL: <name>` |
| Session list | No column-visibility toggle UI | **DONE** — `columnsMenu` bound to `ColumnVisibilityStore` |
| Session list | `selectedProject` / `sortOrder` not persisted | **DONE** — persisted via `@AppStorage` + restore on appear |
| Perf | Service-layer `ISO8601DateFormatter` per-call | **DONE** — shared statics in `SwiftIndexer` + `EngramServiceCommandHandler` |
| Usage (PR5) | Real probe data flow unconfirmed | **INVESTIGATED — not a defect** (see below) |
| Repo hygiene | `.superpowers/` committed by accident | **DONE** — untracked + gitignored (2026-05-23) |

## Verification (2026-05-23)

- New Swift tests, all green: `RepoDiscoveryTests` (3), `IndexAutoTitleTests` (3),
  `SearchModeTests` (2), `TranscriptLabelAndCopyTests` (4),
  `SessionListPersistenceTests` (2).
- Regression: full `EngramCoreTests` and `EngramServiceCore` suites pass;
  `EngramService` builds. App tests run under the developer signing identity
  (team `J25GS8J4XM` applied to host + test bundle).
- Indexer-parity fixture `tests/fixtures/indexer-parity/expected-db-checksums.json`
  updated for the new `generated_title`; `scripts/gen-indexer-parity-fixtures.ts`
  mirrors the Swift title derivation so the fixture stays regen-stable
  (`tests/scripts/stage2-fixture-generators.test.ts` still passes).

## PR5 usage probes — investigation result

Not a defect. `usage_snapshots` is created by migration but never written, the
runtime uses `NoopStartupUsageCollector`, and no `"usage"` service event carries
real data. The UI already degrades correctly: `PopoverUsageSection` is gated on
`!usageData.isEmpty`, so it renders nothing rather than empty/fake bars. Wiring
real Claude-OAuth / Codex-tmux probes is **net-new feature work** (external
integrations), deliberately deferred — not a bug in the current surface.

## Deferred / follow-ups

- **Repo discovery cost:** `RepoDiscovery.discover` shells git inside the writer
  transaction. Fine for typical repo counts; if a user has hundreds of repos,
  move probing outside the write lock.
- **Real usage probes:** implement Claude-OAuth / Codex-tmux collectors writing
  `usage_snapshots`, then surface in `PopoverUsageSection`.
- **Signing config:** `project.yml` sets the app's `DEVELOPMENT_TEAM` to
  `J25GS8J4XM` with a generic "Apple Development" identity (whose cert in the
  keychain is team `AE7P4G8656`). Hosted `EngramTests` need the team passed
  explicitly (`DEVELOPMENT_TEAM=J25GS8J4XM`) or they fail to load with a Team-ID
  mismatch. Consider pinning `DEVELOPMENT_TEAM` on the test target in
  `project.yml` so `xcodebuild test -scheme Engram` works without an override.
