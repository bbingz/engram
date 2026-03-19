# Issues Log

Issues found during autonomous execution that need human attention.

---

## Committed Artifacts (Easy Fix)
Last commit accidentally included `.superpowers/brainstorm/` HTML mockups and `.claude/` files. Run:
```bash
git rm -r --cached .superpowers/ .claude/scheduled_tasks.lock
# Then add to .gitignore if not already present
```

## Remaining Spec Gaps (from 3-round review)

### PR1
- JSON view mode renders same as Text mode (both use RawMessageRow) — spec says JSON should show formatted JSON
- Context menu only has "Copy Message" — spec also asks for "Copy selected" and "Copy entire conversation"
- Tool labels are generic `TOOLS #N` — spec says `TOOL: Read` (with tool name)

### PR2
- Column visibility context menu on table header not implemented — ColumnVisibilityStore exists but has no UI to toggle
- selectedProject and sortOrder are @State, not @AppStorage — don't persist across restarts

### PR3
- Global search overlay is keyword-only — spec says hybrid/keyword/semantic mode selector

### PR5
- No actual usage probes registered (Claude OAuth, Codex tmux) — infra is ready but no probe implementations
- No Swift UI for popover usage bars or Sources page usage display

### PR6
- No RepoDetailView (clicking a repo row does nothing) — spec describes detail page with CLAUDE.md viewer + quick actions
- Git probe runs synchronously on main thread — should use worker_threads (logged, not fixed due to complexity)
- git log format uses `|` separator which breaks on commit messages containing pipe chars

### PR7
- CLI resume (`engram --resume`) entirely missing — spec describes src/cli/resume.ts interactive flow
- Ghostty terminal launch is a no-op (just activates app, doesn't execute command)

### PR8
- titles/regenerate-all endpoint is a stub (returns "started" but does nothing)
- Auto-generate on new session indexing not fully wired (title generator exists in daemon but indexer doesn't call it)
- displayTitle missing firstMessageTruncated fallback step

## Performance Items (from review)
- displayIndexed and matchIndices are expensive computed properties recalculated on every SwiftUI body evaluation — should cache in @State with onChange
- ISO8601DateFormatter allocated per-call in several views — should use shared static instance
- discoverRepos() spawns git process per unique cwd — should cache cwd→repo mappings
