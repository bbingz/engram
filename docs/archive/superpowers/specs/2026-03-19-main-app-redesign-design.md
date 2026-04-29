# Main App Window Redesign — Design Spec

**Date:** 2026-03-19
**Problem:** Engram's standalone window is a scaled-up PopoverView — a flat session list with search. It doesn't surface the richness of Engram's data (15 adapters, tier system, FTS + semantic search, project grouping, index health). Users can't see KPIs, charts, source status, or navigate between functional areas. Compared to dashboard apps like Readout (31 pages, KPI cards, charts, card lists), Engram's UI undersells its backend capabilities.
**Solution:** Redesign the standalone window as a full NavigationSplitView dashboard app with 12 pages across 4 groups, a shared component library, and a data layer mixing GRDB direct reads (fast) with daemon HTTP API calls (for non-DB data).
**Principle:** Ship the skeleton and Home page first (Phase 1), then parallelize page implementation across subagents (Phase 2). Popover remains as a lightweight quick-access entry point unchanged.

---

## 0. Goals And Non-Goals

### Goals

- 12-page dashboard app with NavigationSplitView sidebar navigation.
- Consistent visual design system: KPI cards, section headers, pills/badges, bar charts, card rows.
- Mixed data layer: GRDB for DB queries, daemon HTTP API for file-system data (skills, memory, hooks).
- Home Dashboard with 7 content blocks: KPI row, alert banner, activity chart, When You Work heatmap, source distribution, tier distribution, recent sessions.
- Parallel implementation: once the skeleton + component library is in place, individual pages can be built by independent subagents.

### Non-Goals

- Do not redesign the Popover. It stays as-is for quick access.
- Do not add new daemon features (cost tracking, git integration) in this spec. Use existing data only.
- Do not add a built-in chat/AI assistant (future phase).
- Do not change the Node.js daemon architecture.

---

## 1. Visual Design

### 1a. Style

Hybrid dark theme with macOS native materials:
- Window background: dark (`~#1A1D24`) with system vibrancy on sidebar
- Sidebar: semi-transparent material, `~rgba(255,255,255,0.04)` on dark
- Content area: solid dark background
- Cards/sections: `rgba(255,255,255,0.02)` with `1px rgba(255,255,255,0.04)` border, `10px` corner radius
- Charts: gradient fills with subtle glow (`box-shadow`)
- Supports system appearance switching (dark/light) via SwiftUI `.preferredColorScheme` or system default

### 1b. Color Palette

| Role | Dark Mode | Usage |
|------|-----------|-------|
| Background | `#1A1D24` | Content area |
| Surface | `rgba(255,255,255,0.02)` | Cards, sections |
| Border | `rgba(255,255,255,0.04)` | Card borders |
| Primary text | `#FFFFFF` | Titles, KPI numbers |
| Secondary text | `#A0A1A8` | Labels, descriptions |
| Tertiary text | `#6E7078` | Timestamps, section labels |
| Accent blue | `#4A8FE7` | Selected sidebar, links, claude-code |
| Green | `#30D158` | Success, codex, normal tier |
| Purple | `#A855F7` | Cursor |
| Orange | `#FF9F0A` | Warnings, gemini-cli, lite tier |
| Red | `#FF453A` | Errors, destructive |
| Gray | `#636366` | Skip tier, disabled |

### 1c. Source Colors

Each adapter source gets a consistent color across the entire app:

| Source | Color | Hex |
|--------|-------|-----|
| claude-code | Blue | `#4A8FE7` |
| cursor | Purple | `#A855F7` |
| codex | Green | `#30D158` |
| gemini-cli | Orange | `#FF9F0A` |
| windsurf | Red | `#FF453A` |
| cline | Teal | `#30B0C7` |
| vscode | Cyan | `#00A1F1` |
| Others | Gray | `#8E8E93` |

---

## 2. Navigation Architecture

### 2a. Window Structure

```
NSWindow (standalone, opened via double-click or "Open Window")
└── NSHostingController
    └── MainWindowView
        └── NavigationSplitView
            ├── Sidebar (fixed, ~160px)
            │   ├── ScrollArea (sidebar items)
            │   └── Settings button (pinned bottom)
            └── Detail (content area)
                └── Screen-specific view
```

### 2b. Screen Enum

```swift
enum Screen: String, CaseIterable, Identifiable, Hashable {
    // Overview
    case home
    case search
    // Monitor
    case sessions
    case timeline
    case activity
    // Workspace
    case projects
    case sourcePulse
    // Config
    case skills
    case agents
    case memory
    case hooks
    // System
    case settings

    var id: String { rawValue }
}
```

### 2c. Sidebar Layout

Flat grouped, no disclosure groups. 4 section labels + 12 items + pinned Settings.

```
OVERVIEW
  🏠 Home
  🔍 Search
MONITOR
  💬 Sessions
  📊 Timeline
  ⚡ Activity
WORKSPACE
  📁 Projects
  🔌 Source Pulse
CONFIG
  ⚡ Skills
  🤖 Agents
  🧠 Memory
  🪝 Hooks
──────────
⚙ Settings     ← pinned to bottom
```

Selected item: blue tinted background `rgba(74,143,231,0.25)` with blue text `#6CB4FF`.

### 2d. Integration with Existing Code

- `MenuBarController.openWindow()` creates the new `MainWindowView` instead of `ContentView`
- `ContentView.swift` is kept for the Popover (it hosts the Browse/Search/Timeline/Favorites tabs). The `Notification.Name` extensions (`.openSettings`, `.openWindow`, `.openSession`) and `SessionBox` class defined in `ContentView.swift` remain there — the new `MainWindowView` imports and uses them.
- `PopoverView` remains unchanged (menu bar popover)
- Existing `SearchView.swift`, `FavoritesView.swift`, `TimelineView.swift` remain for Popover use. The new window has separate page files in `Views/Pages/`.
- `SettingsView` becomes a page inside the main window (Screen.settings), AND keeps its standalone window for the Settings menu item
- `DatabaseManager` and `IndexerProcess` are injected as `@EnvironmentObject` (same as current)

### 2e. Prerequisites — Session Model Update

The Swift `Session` struct in `Models/Session.swift` must be updated before any new page can work:

1. Add `let tier: String?` property + CodingKey mapping. Required by `tierDistribution()`, `TierBar` component, and tier-based filtering.
2. Add `let toolMessageCount: Int` property + CodingKey mapping. Required by Activity page breakdowns.

### 2f. Source Color Unification

The existing `SourceDisplay.color()` in `SessionDetailView.swift` and `SourceBadge.color` in `SearchView.swift` use different colors than the new design system (§1c). As part of Phase 1, create `SourceColors.swift` as the single source of truth for source→color mapping, and refactor both existing callsites to use it. This ensures consistent colors across Popover and main window.

---

## 3. Shared Component Library

All pages reuse these components. Implemented once in `macos/Engram/Components/`.

### 3a. KPICard

Displays a large number with a label below.

```
┌─────────────┐
│    1,346    │  ← large number, white, bold
│   Sessions  │  ← small label, gray
└─────────────┘
```

Properties: `value: String`, `label: String`, optional `delta: String` ("+12%"), optional `deltaPositive: Bool`.

Background: surface color with border. Corner radius 10px.

### 3b. SectionHeader

```
📊 Activity  30d  🔄        View All →
```

Properties: `icon: String` (SF Symbol), `title: String`, optional `badge: String`, optional `onRefresh: (() -> Void)?`, optional `trailingAction: (label: String, action: () -> Void)?`.

### 3c. SourcePill

Small colored rounded rectangle showing the source name.

```
claude-code    cursor    codex
```

Properties: `source: String`. Color auto-mapped from source color table (§1c).

### 3d. ProjectBadge

Similar to SourcePill but with lighter background opacity — shows the project name.

Properties: `project: String`, `source: String` (for color matching).

### 3e. SessionCard (Row)

```
[source-pill] Session summary text...  [project-badge]  252 msgs · 2h ago  ›
```

Full-width row used in session lists. Properties: session data object. Taps to navigate to session detail.

### 3f. BarChart

Horizontal bar chart for source distribution, tool usage, etc.

```
claude-code  ████████████████████░░░  847
cursor       █████░░░░░░░░░░░░░░░░░  198
codex        ████░░░░░░░░░░░░░░░░░░  112
```

Properties: `items: [(label: String, value: Int, color: Color)]`.

### 3g. ActivityChart

Vertical bar chart showing daily session counts over N days.

Properties: `data: [(date: Date, count: Int)]`, `days: Int` (default 30).

### 3h. HeatmapGrid

Grid of colored cells showing intensity (e.g., When You Work).

Properties: `data: [Int]` (24 values for hours), `colorBase: Color`.

### 3i. TierBar

Stacked horizontal bar showing tier distribution with legend.

Properties: `premium: Int`, `normal: Int`, `lite: Int`, `skip: Int`.

### 3j. AlertBanner

```
⚠ 2 sources need re-scan · antigravity adapter has 0 sessions    View Sources →
```

Orange-tinted background. Properties: `message: String`, optional `action: (label: String, action: () -> Void)?`.

### 3k. EmptyState

Centered placeholder for pages with no data.

```
        [SF Symbol]
     No sessions found
  Try adjusting your filters
```

Properties: `icon: String`, `title: String`, `message: String`, optional `action: (label: String, action: () -> Void)?`.

### 3l. SkeletonRow

Animated loading placeholder. Gray rounded rectangles with shimmer animation.

### 3m. FilterPills

Horizontal row of selectable time-range pills.

```
[Today] [This Week] [This Month] [All Time]
```

Properties: `options: [String]`, `selected: Binding<String>`.

---

## 4. Data Layer

### 4a. GRDB Direct Reads (DB data)

Extend `DatabaseManager` with new query methods:

| Method | Returns | Used By |
|--------|---------|---------|
| `kpiStats()` | `(sessions: Int, sources: Int, messages: Int, projects: Int)` | Home KPI |
| `dailyActivity(days: Int)` | `[(date: String, count: Int)]` | Home Activity chart |
| `hourlyActivity()` | `[Int]` (24 values, use `strftime('%H', start_time, 'localtime')`) | Home When You Work |
| `sourceDistribution()` | `[(source: String, count: Int)]` | Home Sources chart |
| `tierDistribution()` | `[(tier: String, count: Int)]` | Home Tier chart |
| `recentSessions(limit: Int)` | `[Session]` | Home Recent Sessions |
| `listSessionsByProject()` | `[String: [Session]]` | Projects page |
| `sessionTimeline(days: Int)` | `[(date: String, sessions: [Session])]` | Timeline page |
| `searchSessions(query:)` | existing FTS | Search page |

All methods are read-only using the existing GRDB pool. No schema changes needed — all data already exists in the `sessions` table.

### 4b. Daemon HTTP API (non-DB data)

Extend the Hono web server with new endpoints. Swift calls these via `URLSession`.

| Endpoint | Returns | Used By |
|----------|---------|---------|
| `GET /api/sources` | Adapter names, detect status, session counts | Source Pulse |
| `GET /api/skills` | List of installed skills (from `~/.claude/`) | Skills page |
| `GET /api/memory` | Memory files across projects | Memory page |
| `GET /api/hooks` | Configured hooks from settings | Hooks page |
| `GET /api/health/sources` | Already exists | Source Pulse alerts |

Note: Agents page uses GRDB directly (sessions WHERE agentRole IS NOT NULL), no daemon API needed.

### 4c. Swift API Client

New `DaemonClient` class in Swift. Uses `ObservableObject` to match the existing `DatabaseManager`/`IndexerProcess` pattern:

```swift
class DaemonClient: ObservableObject {
    private let baseURL: String  // http://127.0.0.1:3457

    func fetch<T: Decodable>(_ path: String) async throws -> T
}
```

Injected via `@EnvironmentObject` (same as `DatabaseManager` and `IndexerProcess`). Created in `AppDelegate` and passed through the view hierarchy.

---

## 5. Page Specifications

### 5a. Home Dashboard

**Route:** `Screen.home`
**File:** `Views/Pages/HomeView.swift`
**Data:** All from GRDB (no HTTP calls needed)

Layout (top to bottom, scrollable):
1. Greeting: "Good afternoon, {username}" + summary line
2. KPI row: 4 × `KPICard` (Sessions, Sources, Messages, Projects)
3. Alert banner: shown if any source has 0 sessions or health issues
4. Two-column: `ActivityChart` (30d) + `HeatmapGrid` (When You Work)
5. Two-column: `BarChart` (Source distribution) + `TierBar` (Tier distribution)
6. `SectionHeader` ("Recent Sessions") + list of `SessionCard` (limit 8)

### 5b. Search

**Route:** `Screen.search`
**File:** `Views/Pages/SearchView.swift` (evolve from existing `SearchView.swift`)
**Data:** GRDB FTS + daemon API for semantic search

Layout:
1. Search bar (full width)
2. `FilterPills` (Today / This Week / This Month / All Time)
3. Results as `SessionCard` list
4. `EmptyState` when no results

### 5c. Sessions

**Route:** `Screen.sessions`
**File:** `Views/Pages/SessionsPageView.swift`
**Data:** GRDB

Layout:
1. KPI row: 3 × `KPICard` (Total Sessions, Messages, Avg Duration)
2. `FilterPills` (time range) + source filter dropdown
3. `SessionCard` list (paginated or lazy-loaded)
4. Tap → existing `SessionDetailView`

### 5d. Timeline

**Route:** `Screen.timeline`
**File:** `Views/Pages/TimelinePageView.swift`
**Data:** GRDB `sessionTimeline()`

Layout:
1. Date-grouped session list (like git log)
2. Each date group: date header + `SessionCard` rows
3. Scrollable, lazy-loaded

### 5e. Activity

**Route:** `Screen.activity`
**File:** `Views/Pages/ActivityView.swift`
**Data:** GRDB

Layout:
1. KPI row: Active Sources, Sessions Today, Sessions This Week
2. `ActivityChart` (30d, larger version)
3. `HeatmapGrid` (full-width, 7 days × 24 hours)
4. Source-by-source activity breakdown (bar charts per source)

### 5f. Projects

**Route:** `Screen.projects`
**File:** `Views/Pages/ProjectsView.swift`
**Data:** GRDB `listSessionsByProject()`

Layout:
1. KPI row: Total Projects, Active (last 7d), Avg Sessions/Project
2. Project card list, each showing: project name + session count pill + last active time
3. Tap → project detail (filtered session list)

### 5g. Source Pulse

**Route:** `Screen.sourcePulse`
**File:** `Views/Pages/SourcePulseView.swift`
**Data:** GRDB `sourceDistribution()` + daemon `GET /api/sources` + `GET /api/health/sources`

Layout:
1. KPI row: Active Sources, Total Indexed, Last Scan
2. Source card list: source name + `SourcePill` + session count + status (healthy/warning/error)
3. Each card expandable to show adapter details

### 5h. Skills

**Route:** `Screen.skills`
**File:** `Views/Pages/SkillsView.swift`
**Data:** Daemon `GET /api/skills`

Layout:
1. Search bar
2. Section: Global skills (from `~/.claude/settings.json` or plugins)
3. Section: Per-project skills
4. Each skill: name + description + source path
5. `EmptyState` if no skills found

### 5i. Agents

**Route:** `Screen.agents`
**File:** `Views/Pages/AgentsView.swift`
**Data:** GRDB (sessions WHERE agentRole IS NOT NULL)

Layout:
1. KPI row: Total Agent Sessions, Active Agents (last 7d)
2. Agent session list as `SessionCard` with agent role badge
3. `EmptyState` if no agent sessions

### 5j. Memory

**Route:** `Screen.memory`
**File:** `Views/Pages/MemoryView.swift`
**Data:** Daemon `GET /api/memory`

Layout:
1. Search bar
2. Per-project memory files list
3. Each memory: file name + project + size + preview
4. Tap → view full memory content (Markdown rendered)

### 5k. Hooks

**Route:** `Screen.hooks`
**File:** `Views/Pages/HooksView.swift`
**Data:** Daemon `GET /api/hooks`

Layout:
1. Hook list: event type + command + source (global/project)
2. Each hook shown as a card row
3. `EmptyState` if no hooks configured

### 5l. Settings

**Route:** `Screen.settings`
**File:** Reuse existing `Views/SettingsView.swift`

Embedded in NavigationSplitView detail area. Same content as current standalone settings window.

---

## 6. Implementation Phases

### Phase 1 — Skeleton (Serial)

Must be done sequentially. Creates the foundation all pages depend on.

| Task | Deliverable |
|------|-------------|
| 1. Screen enum + MainWindowView + Sidebar | Navigation shell, all 12 routes stub views |
| 2. Component library | KPICard, SectionHeader, SourcePill, SessionCard, BarChart, etc. |
| 3. DB query extensions | `kpiStats()`, `dailyActivity()`, `sourceDistribution()`, etc. on DatabaseManager |
| 4. Daemon API endpoints | `/api/sources`, `/api/skills`, `/api/memory`, `/api/hooks` |
| 5. DaemonClient Swift class | HTTP client for daemon API |
| 6. Home Dashboard | `HomeView.swift` with all 7 blocks wired to real data |
| 7. Wire into MenuBarController | `openWindow()` creates `MainWindowView` instead of `ContentView` |

### Phase 2 — Pages (Parallel)

Each page is independent. Can be built by parallel subagents in separate worktrees.

**Batch A** (GRDB-only, no daemon API needed):
- Sessions page
- Timeline page
- Activity page
- Projects page
- Agents page

**Batch B** (needs daemon API endpoints from Phase 1 Task 4):
- Source Pulse page
- Skills page
- Memory page
- Hooks page

**Batch C** (migration):
- Search page (evolve existing SearchView)
- Settings page (embed existing SettingsView)

---

## 7. File Structure

```
macos/Engram/
├── App.swift                          (modify: no changes needed)
├── MenuBarController.swift            (modify: openWindow → MainWindowView)
├── Core/
│   ├── Database.swift                 (modify: add query methods)
│   ├── DaemonClient.swift             (NEW: HTTP client)
│   ├── IndexerProcess.swift           (no changes)
│   └── ...existing files...
├── Components/                        (NEW directory)
│   ├── KPICard.swift
│   ├── SectionHeader.swift
│   ├── SourcePill.swift
│   ├── ProjectBadge.swift
│   ├── SessionCard.swift
│   ├── BarChart.swift
│   ├── ActivityChart.swift
│   ├── HeatmapGrid.swift
│   ├── TierBar.swift
│   ├── AlertBanner.swift
│   ├── EmptyState.swift
│   ├── SkeletonRow.swift
│   ├── FilterPills.swift
│   └── SourceColors.swift             (color mapping)
├── Models/
│   ├── Session.swift                  (modify: add tier, toolMessageCount)
│   └── Screen.swift                   (NEW: enum)
├── Views/
│   ├── MainWindowView.swift           (NEW: NavigationSplitView shell)
│   ├── SidebarView.swift              (NEW)
│   ├── PopoverView.swift              (no changes)
│   ├── SessionDetailView.swift        (no changes)
│   ├── SettingsView.swift             (no changes, reused)
│   ├── Pages/                         (NEW directory)
│   │   ├── HomeView.swift
│   │   ├── SearchPageView.swift
│   │   ├── SessionsPageView.swift
│   │   ├── TimelinePageView.swift
│   │   ├── ActivityView.swift
│   │   ├── ProjectsView.swift
│   │   ├── SourcePulseView.swift
│   │   ├── SkillsView.swift
│   │   ├── AgentsView.swift
│   │   ├── MemoryView.swift
│   │   └── HooksView.swift
│   └── ...existing views (kept)...
└── project.yml                        (modify: add new files)
```

TypeScript side:
```
src/
├── web.ts                             (modify: add new API endpoints)
└── ...no other changes...
```

---

## 8. Scope Boundary

This spec covers:
- Window architecture (NavigationSplitView + routing)
- Visual design system and component library
- All 12 page layouts and data sources
- DB query extensions and daemon API endpoints
- Integration with existing MenuBarController

This spec does NOT cover:
- Cost tracking (no token/cost data yet)
- Git integration (diffs, timeline of commits)
- Built-in AI chat assistant
- Workspace snapshots
- Any changes to the Popover
- Any changes to the Node.js daemon architecture (only new HTTP endpoints)
