# PR6: Workspace — Git Repo Management — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Workspace section to the sidebar with Repos (list + detail), Work Graph (commit activity), using real-time git probing of repos discovered from session cwd paths.

**Architecture:** Node daemon discovers git repos from all session.cwd, probes them periodically (git status/branch/log in worker threads), stores results in `git_repos` table. Swift reads via GRDB and renders 3 new pages. Quick actions launch Terminal/IDE/Finder.

**Tech Stack:** TypeScript (worker_threads, child_process), SQLite, SwiftUI, git CLI

**Spec:** `docs/superpowers/specs/2026-03-19-eight-prs-learning-from-agent-sessions-design.md` (PR6 section)

---

## File Structure

### New Files (Node)
| File | Responsibility |
|------|---------------|
| `src/core/git-probe.ts` | Discover repos from session.cwd, run git commands in worker, store results |
| `tests/git-probe.test.ts` | Test repo discovery and git status parsing |

### New Files (Swift)
| File | Responsibility |
|------|---------------|
| `macos/Engram/Views/Workspace/ReposView.swift` | KPI cards + Active/Recent repo list |
| `macos/Engram/Views/Workspace/RepoDetailView.swift` | Repo detail: branch, commit, quick actions, CLAUDE.md, sessions |
| `macos/Engram/Views/Workspace/WorkGraphView.swift` | Commit activity chart + commits by repo |
| `macos/Engram/Models/GitRepo.swift` | GRDB FetchableRecord for git_repos table |

### Modified Files
| File | Changes |
|------|---------|
| `src/core/db.ts` | Add `git_repos` table migration |
| `src/web.ts` | Add `GET /api/repos`, `GET /api/repos/:name` endpoints |
| `src/daemon.ts` | Start git probe after indexer ready |
| `macos/Engram/Views/SidebarView.swift` | Add WORKSPACE section (Repos, Work Graph) |
| `macos/Engram/Views/MainWindowView.swift` | Add routing for .repos, .workGraph screens |
| `macos/Engram/Core/Database.swift` | Add git_repos queries to DatabaseManager class |

---

## Task 1: DB Migration + Git Repo Model

- [ ] **Step 1: Add git_repos table in db.ts migrate()**

```sql
CREATE TABLE IF NOT EXISTS git_repos (
  path TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  branch TEXT,
  dirty_count INTEGER DEFAULT 0,
  untracked_count INTEGER DEFAULT 0,
  unpushed_count INTEGER DEFAULT 0,
  last_commit_hash TEXT,
  last_commit_msg TEXT,
  last_commit_at TEXT,
  session_count INTEGER DEFAULT 0,
  probed_at TEXT
)
```

- [ ] **Step 2: Add GET /api/repos in web.ts**

Return all repos sorted by last_commit_at DESC, joined with session counts.

- [ ] **Step 3: Create Swift GitRepo model**

```swift
struct GitRepo: FetchableRecord, Decodable, Identifiable {
    var id: String { path }
    let path: String
    let name: String
    let branch: String?
    let dirtyCount: Int
    let untrackedCount: Int
    let unpushedCount: Int
    let lastCommitHash: String?
    let lastCommitMsg: String?
    let lastCommitAt: String?
    let sessionCount: Int
    let probedAt: String?
}
```

- [ ] **Step 4: Add listGitRepos() to DatabaseManager in Database.swift**
- [ ] **Step 5: Commit**

`git commit -m "feat(workspace): add git_repos table, API, and Swift model"`

---

## Task 2: Git Probe (Node)

- [ ] **Step 1: Create src/core/git-probe.ts**

Key functions:
- `discoverRepos(db)`: query distinct `cwd` from sessions, run `git rev-parse --show-toplevel` for each, deduplicate
- `probeRepo(repoPath)`: run in worker thread: `git branch --show-current`, `git status --porcelain`, `git log --oneline -1`, `git rev-list --count @{push}..HEAD` (unpushed)
- `startGitProbeLoop(db, interval=300000)`: timer, calls discoverRepos then probeRepo for each, upserts git_repos table

**Critical:** All git commands MUST run in `worker_threads` or `child_process.exec` to avoid blocking daemon event loop.

- [ ] **Step 2: Tests for git status parsing**
- [ ] **Step 3: Wire into daemon.ts — start after indexer ready**
- [ ] **Step 4: Commit**

`git commit -m "feat(workspace): add git probe with worker thread isolation"`

---

## Task 3: Sidebar + Routing

- [ ] **Step 1: Add Repos and Work Graph to existing WORKSPACE sidebar section**

The WORKSPACE section already exists in `Screen.Section` (in `Models/Screen.swift`) with `.projects` and `.sourcePulse`. Add `.repos` and `.workGraph` cases to the `Screen` enum and place them in the existing WORKSPACE section. Keep `.projects` (it serves a different purpose — session grouping by project, while Repos shows git status). Reorder to: Repos, Projects, Work Graph, Sources.

- [ ] **Step 2: Add Screen cases and routing in MainWindowView**

Add `.repos` and `.workGraph` to Screen enum in `Models/Screen.swift`, route to ReposView and WorkGraphView in MainWindowView.

- [ ] **Step 3: Commit**

`git commit -m "feat(workspace): add Workspace sidebar section and routing"`

---

## Task 4: ReposView

- [ ] **Step 1: Create ReposView**

KPI cards row: Active | Dirty | Unpushed | Total. Below: two sections "Active" (24h) and "Recent" (7d). Each row: repo name (bold) + branch pill + dirty/unpushed badges + last commit + sparkline placeholder + "›" chevron.

- [ ] **Step 2: Active/Recent classification**

Active = lastCommitAt within 24h OR sessionCount changed recently. Recent = within 7d. Dormant = older.

- [ ] **Step 3: NavigationLink to RepoDetailView**
- [ ] **Step 4: Commit**

`git commit -m "feat(workspace): add ReposView with KPI cards and repo list"`

---

## Task 5: RepoDetailView

- [ ] **Step 1: Create RepoDetailView**

Header: breadcrumb "‹ Repos > {name}", branch, last commit. Quick action buttons: Claude, VS Code, Terminal, Git Pull, Finder, Copy Path. CLAUDE.md content viewer (read file from `{path}/CLAUDE.md`). Related sessions list from DB.

- [ ] **Step 2: Quick action implementations**

```swift
// VS Code
NSWorkspace.shared.open(URL(fileURLWithPath: repo.path), configuration: .init(), completionHandler: nil)
// Terminal
Process.launchedProcess(launchPath: "/usr/bin/open", arguments: ["-a", "Terminal", repo.path])
// Finder
NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: repo.path)
// Git Pull
Task { Process.launchedProcess(launchPath: "/usr/bin/git", arguments: ["-C", repo.path, "pull"]) }
// Copy Path
NSPasteboard.general.clearContents(); NSPasteboard.general.setString(repo.path, forType: .string)
```

- [ ] **Step 3: Commit**

`git commit -m "feat(workspace): add RepoDetailView with quick actions and CLAUDE.md viewer"`

---

## Task 6: WorkGraphView

- [ ] **Step 1: Create WorkGraphView**

KPI cards: Active | Idle | Dormant | Commits (30d). Commit Activity bar chart (use Swift Charts `BarMark`). Commits by Repo horizontal bar chart. AI Sessions by Repo (from session DB).

- [ ] **Step 2: Data fetching**

Call `GET /api/repos` for repo data. Compute chart data client-side from git_repos table.

- [ ] **Step 3: Commit**

`git commit -m "feat(workspace): add WorkGraphView with activity charts"`

---

## Task 7: Final Verification

- [ ] **Step 1: npm test + npm run build**
- [ ] **Step 2: xcodegen generate + full Xcode build**
- [ ] **Step 3: Smoke test** — sidebar shows Workspace, Repos page shows repos with git status, detail shows CLAUDE.md + quick actions, Work Graph shows charts
- [ ] **Step 4: Final commit**

`git commit -m "feat(workspace): PR6 complete — git repo management center"`
