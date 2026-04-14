# PR2: Session List Redesign — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the card-based grouped session list with a sortable table, add an Agent filter bar with colored pills above the table, and add a Project fuzzy-search input.

**Architecture:** Replace SessionListView's sidebar List+DisclosureGroup with SwiftUI `Table`. Agent filter bar sits above the table as pill buttons derived from DB source counts. Project search is a popover TextField with fuzzy-match dropdown. Column visibility managed via @AppStorage bitmask.

**Tech Stack:** SwiftUI Table (macOS 13+), existing DatabaseManager queries, @AppStorage persistence

**Spec:** `docs/superpowers/specs/2026-03-19-eight-prs-learning-from-agent-sessions-design.md` (PR2 section)

---

## File Structure

### New Files
| File | Responsibility |
|------|---------------|
| `macos/Engram/Views/SessionList/AgentFilterBar.swift` | Horizontal pill bar: All + per-agent pills with counts, multi-select |
| `macos/Engram/Views/SessionList/ProjectSearchField.swift` | 3-state search: placeholder → input+dropdown → selected pill |
| `macos/Engram/Views/SessionList/ColumnVisibilityStore.swift` | @AppStorage wrapper for column show/hide state |
| `macos/Engram/Views/SessionList/SessionTableView.swift` | SwiftUI Table with sortable columns, row selection, favorite toggle |

### Modified Files
| File | Changes |
|------|---------|
| `macos/Engram/Views/SessionListView.swift` | Rewrite to compose AgentFilterBar + ProjectSearchField + SessionTableView. Remove old sidebar/grouping logic |
| `macos/Engram/Core/DatabaseManager.swift` | Add `countsBySource()` query if not already present |

---

## Task 1: ColumnVisibilityStore

**Files:** Create: `macos/Engram/Views/SessionList/ColumnVisibilityStore.swift`

- [ ] **Step 1: Create ColumnVisibilityStore**

Observable class with @AppStorage for each column (favorite, agent, title, date, project, msgs, size). Each is a Bool defaulting to true. Provides a `changeToken` Int that increments on any visibility change (prevents SwiftUI layout animation on hide).

- [ ] **Step 2: Build verify**

Run: `cd macos && xcodegen generate && xcodebuild -scheme Engram -configuration Debug build 2>&1 | tail -5`

- [ ] **Step 3: Commit**

`git commit -m "feat(list): add ColumnVisibilityStore for table column visibility"`

---

## Task 2: AgentFilterBar

**Files:** Create: `macos/Engram/Views/SessionList/AgentFilterBar.swift`

- [ ] **Step 1: Create AgentFilterBar**

HStack of pill buttons. Props: `sourceCounts: [(source: String, count: Int)]`, `selectedSources: Binding<Set<String>>`. "All" button resets selection. Each pill shows `SourceColors.color(for:)` dot + label + count. Multi-select: tap toggles source in/out of set. Unselected pills are gray. Only show sources with count > 0.

- [ ] **Step 2: Wire @AppStorage persistence**

Use existing `selectedSourcesStr` @AppStorage (tab-delimited) converted to `Set<String>`.

- [ ] **Step 3: Build verify and commit**

`git commit -m "feat(list): add AgentFilterBar with multi-select agent pills"`

---

## Task 3: ProjectSearchField

**Files:** Create: `macos/Engram/Views/SessionList/ProjectSearchField.swift`

- [ ] **Step 1: Create ProjectSearchField with 3 states**

State machine: `.idle` (shows "Project..." placeholder), `.searching(query)` (expanded TextField + dropdown), `.selected(project)` (blue pill with ×).

- [ ] **Step 2: Add fuzzy match dropdown**

When typing, filter `allProjects: [(name: String, count: Int)]` by case-insensitive contains. Show matches in a floating overlay with project name + session count. ↑↓ keyboard navigation, Enter to select.

- [ ] **Step 3: Wire to @AppStorage**

Store selected project in existing `selectedProjectsStr` @AppStorage.

- [ ] **Step 4: Build verify and commit**

`git commit -m "feat(list): add ProjectSearchField with fuzzy-match dropdown"`

---

## Task 4: SessionTableView

**Files:** Create: `macos/Engram/Views/SessionList/SessionTableView.swift`

- [ ] **Step 1: Create SwiftUI Table**

Columns: ★ (28pt), Agent (64pt), Title (flexible), Date (90pt), Project (90pt), Msgs (44pt), Size (50pt). Use `Table(sessions, selection:, sortOrder:)` with `KeyPathComparator`.

- [ ] **Step 2: Implement favorite toggle in ★ column**

★ column uses a `Button` that calls `db.addFavorite`/`db.removeFavorite`. Star icon: filled yellow if favorite, outline gray if not.

- [ ] **Step 3: Implement column visibility**

Read `ColumnVisibilityStore` via @EnvironmentObject. Hidden columns use `.width(min: 0, ideal: 0, max: 0)`. Right-click context menu on any column header area toggles visibility.

- [ ] **Step 4: Alternating row backgrounds**

Use `.alternatingRowBackgrounds(.enabled)` modifier on Table (macOS 14+).

- [ ] **Step 5: Build verify and commit**

`git commit -m "feat(list): add SessionTableView with sortable columns and favorites"`

---

## Task 5: Rewrite SessionListView

**Files:** Modify: `macos/Engram/Views/SessionListView.swift`

- [ ] **Step 1: Replace body with new composition**

```
VStack(spacing: 0) {
    AgentFilterBar(sourceCounts: sourceCounts, selectedSources: $selectedSources)
    // with ProjectSearchField on the right
    Divider()
    SessionTableView(sessions: filteredSessions, ...)
    // Footer: session count + Clean Empty
}
```

- [ ] **Step 2: Preserve existing filter logic**

Keep: source filter, project filter, agent filter mode, sort field/direction. Adapt from Set-based to Table sortOrder. Keep footer with session count and "Clean Empty" button.

- [ ] **Step 3: Remove old sidebar/grouping code**

Remove: DisclosureGroup, groupingMode, manual grouping logic, old sort buttons. Keep the data loading `.task` and DatabaseManager queries.

- [ ] **Step 4: Verify all filters work end-to-end**

Test: click agent pills → table filters. Type in project search → table filters. Click column header → table sorts. Click ★ → favorite toggles.

- [ ] **Step 5: Commit**

`git commit -m "feat(list): rewrite SessionListView with table, agent filter, project search"`

---

## Task 6: Footer and Clean Empty

**Files:** Modify: `macos/Engram/Views/SessionListView.swift`

- [ ] **Step 1: Add footer bar**

HStack at bottom: left = "{N} sessions" count, right = "Clean Empty" button (existing logic).

- [ ] **Step 2: Build, smoke test, commit**

`git commit -m "feat(list): add session count footer and preserve Clean Empty"`

---

## Task 7: Final Integration

- [ ] **Step 1: xcodegen generate**
- [ ] **Step 2: Full build verify**
- [ ] **Step 3: Manual smoke test** — agent pills, project search, table sort, column visibility, favorites, footer
- [ ] **Step 4: Final commit**

`git commit -m "feat(list): PR2 complete — table-based session list with filters"`
