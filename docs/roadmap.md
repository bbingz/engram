# Engram Roadmap

Canonical pending-work list. Supersedes the per-PR gap notes in
`tasks/issues.md`, which were written 2026-04-29 against the Node-era spec and
are now mostly stale.

Status as of **2026-05-23**, established by re-verifying every open item in
`tasks/issues.md` against the **Swift product** (`macos/`). TypeScript under
`src/` is dev/reference only; the Node runtime is no longer in the product, so
several spec items are obsolete by construction.

## Status table

| Area | Item | Verdict | Priority |
|------|------|---------|----------|
| Workspace | `git_repos` never populated — no repo discovery code; Repos page is dormant/empty | OPEN | **High** |
| Indexing | Auto-generate title on new-session index not wired (`generated_title` stays NULL) | OPEN | Med |
| Search | `SearchView` exposes a `semantic` mode toggle, but product search is keyword-only (no sqlite-vec) — advertised-but-inert | OPEN | Med |
| Search | `GlobalSearchOverlay` hardcodes "hybrid" mode with no selector (same root cause as above) | OPEN | Low |
| Transcript | Context menu only has "Copy Message"; no "Copy selected" / "Copy entire conversation" | OPEN | Low |
| Transcript | Tool rows render generic `TOOLS #N`, not `TOOL: <name>` (e.g. `TOOL: Read`) | OPEN | Low |
| Session list | `ColumnVisibilityStore` exists + persists, but no header context-menu UI to toggle columns | OPEN | Low |
| Session list | `selectedProject` / `sortOrder` are `@State`, not `@AppStorage` — don't persist across restarts | OPEN | Low |
| Perf | `ISO8601DateFormatter` shared in UI components, still allocated per-call in service layer | OPEN | Low |
| Usage (PR5) | Popover usage bars + service plumbing exist; whether real Claude-OAuth / Codex-tmux probe data flows is unconfirmed | INVESTIGATE | Med |
| Repo hygiene | `.superpowers/` brainstorm artifacts (44 files) committed by accident; should be untracked + gitignored | OPEN | Low |

## Open items (detail)

### High — Repos / Workspace feature is dormant
`git_repos` table is created in `EngramCoreWrite/Database/EngramMigrations.swift`
(~L162) and read by `Engram/Core/Database.swift` `listGitRepos()`, but **no Swift
code ever writes to it**. The old populator was Node `src/core/git-probe.ts`
(the `%H|%s|%aI` pipe-separated `git log`), which left the product when Node did.
Result: `ReposView` always shows "No repos discovered". `RepoDetailView` itself
is fully implemented (navigation, CLAUDE.md viewer, quick actions) and repo reads
already run off-main via `Task.detached` — only the discovery/ingest half is
missing.

Fix direction: add a Swift repo-discovery pass (likely in `EngramService` /
`EngramCoreWrite`) that derives repos from session `cwd`s, shells `git` safely
(NUL-separated `--pretty`, never `|`), and writes `git_repos`. This also retires
the old pipe-separator bug by never reintroducing it.

### Med — Auto-title on indexing
`EngramCoreWrite/Indexing/SwiftIndexer.swift` `buildSnapshot()` (~L195-241) never
sets `generated_title`. Titles are only filled by the on-demand
`regenerateAllTitles` service command (which works and is tested). New sessions
index with `generated_title = NULL` and fall back to `summary` / "Untitled" in
the UI. Decide: call `nativeTitle()`-equivalent during index, or have the service
backfill titles for freshly indexed rows.

### Med — Search "semantic" mode is a false promise
`Engram/Views/.../SearchView.swift` (~L71-86) renders hybrid/keyword/**semantic**
toggle buttons, but per `CLAUDE.md` the product search is keyword-only (FTS5/LIKE)
and `SQLiteVecSupport.swift` reports sqlite-vec "not implemented". Either hide the
semantic/hybrid options until vector search ships, or implement sqlite-vec.
`GlobalSearchOverlay` (~L107) hardcoding `mode = hybrid` is the same root cause.

### Med (investigate) — PR5 usage probes
`PopoverUsageSection` + `IndexerProcess` usage-event parsing + `PopoverView`
wiring all exist; data comes from `serviceStatusStore.usageData`. No Swift probe
implementation (Claude OAuth / Codex tmux) was found in `macos/`. Confirm whether
the service backend actually emits real usage data or the bars render empty.

### Low — UI/polish backlog
- Transcript copy actions: add "Copy selected" / "Copy entire conversation"
  (`Views/Transcript/ColorBarMessageView.swift` context menu, ~L135).
- Tool label specificity: surface the tool name instead of `TOOLS #N`
  (`Models/MessageTypeClassifier.swift` + `ColorBarMessageView.swift` ~L12).
- Column-visibility toggle UI on the session-table header (store already exists).
- Persist `selectedProject` / `sortOrder` via `@AppStorage`.
- Replace per-call `ISO8601DateFormatter()` allocations in the service layer
  (e.g. `EngramServiceCommandHandler.swift`, `SwiftIndexer.swift`) with shared
  static instances, matching what UI components already do.

### Low — Repo hygiene
`.superpowers/brainstorm/**` (HTML mockups, `.server.log`, `.server.pid`) is
tracked in git. Untrack via `git rm -r --cached .superpowers` and add to
`.gitignore`. (`.claude/scheduled_tasks.lock` is already untracked.)

## Resolved / obsolete since 2026-04-29 (closed out)

Verified resolved in the Swift product (no longer roadmap items):

- **claude-code `file_path`** — `ClaudeCodeAdapter.swift` populates `filePath`
  from the locator; the Node-era empty-`file_path` bug is gone.
- **PR1 JSON view mode** — removed as a false promise (UI-M2); only Session/Text
  modes remain.
- **PR6 RepoDetailView** — fully implemented (the missing half is discovery, see
  High item above).
- **PR6 git probe on main thread** — repo reads run off-main; product no longer
  shells git for discovery at all.
- **PR6 git-log `|` separator** — obsolete; the pipe-parsing lived in removed
  Node `git-probe.ts`. No Swift `|`-separated git parsing exists.
- **PR7 CLI resume** — ported to the Swift service as `resumeCommand()`
  (`EngramService/Core/EngramServiceReadProvider.swift` ~L450) for all sources.
- **PR7 Ghostty launch** — `Views/Resume/TerminalLauncher.swift` spawns a real
  `Process` (`-e` + shell command), with AppleScript fallback; not a no-op.
- **PR8 regenerate-all titles** — functional service command, tested.
- **PR8 displayTitle fallback** — `Models/Session.swift` falls back
  custom → generated → summary → "Untitled".
- **Perf: displayIndexed / matchIndices** — now `@State`, updated via
  `.onChange`, not recomputed every body eval.
