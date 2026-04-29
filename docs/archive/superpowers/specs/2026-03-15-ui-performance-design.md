# UI Performance Optimization — Design Spec

**Date:** 2026-03-15
**Problem:** Every UI surface (popover, session list, timeline, search, detail) drops frames on open/interact.
**Root causes:** DB calls isolated to `@MainActor` block the main thread even inside `Task {}`; DateFormatter allocation in loops; missing debounce on filter changes.
**Approach:** A (async data loading) + B (render optimization).

---

## 0. Foundation: DatabaseManager Actor Isolation

**File:** `macos/Engram/Core/Database.swift`

**Current:** `DatabaseManager` is `@MainActor`-isolated. ALL methods — including read-only queries — execute on the main thread. GRDB's `DatabasePool.read` is internally thread-safe, but callers cannot reach it from a background thread because Swift enforces actor isolation at the call site.

**Change:** Add `nonisolated` read-only methods that access the pool directly, bypassing `@MainActor` isolation. The GRDB pool is thread-safe, so this is safe:

```swift
@MainActor
class DatabaseManager: ObservableObject {
    // Existing pool (set in open())
    private var pool: DatabasePool?

    // New: thread-safe read accessor for background use
    nonisolated func readInBackground<T>(_ block: (GRDB.Database) throws -> T) throws -> T {
        guard let pool = pool else { throw DatabaseError.notOpen }
        return try pool.read(block)
    }
}
```

All async view loading will use `readInBackground` from `Task.detached` or `Task { }` (non-MainActor). Existing synchronous `@MainActor` methods remain unchanged for backward compatibility.

**This is the prerequisite for all sections below.**

---

## 1. PopoverView — Async Data Loading

**File:** `macos/Engram/Views/PopoverView.swift`

**Current:** `.onAppear { loadData() }` calls 4 DB methods. Even though it's inside the view, all calls go through `@MainActor`-isolated `DatabaseManager`, blocking the main thread.

**Change:**
- Replace `.onAppear` with `.task { await loadData() }`
- `loadData()` uses `readInBackground` inside a non-main-actor Task:

```swift
func loadData() async {
    let result = await Task.detached { [db] in
        let counts = try? db.readInBackground { d in /* countsBySource query */ }
        let sessions = try? db.readInBackground { d in /* listSessionsChronologically */ }
        let size = try? db.readInBackground { d in /* dbSizeBytes */ }
        return (counts, sessions, size)
    }.value
    // Assign on main actor (implicit, since view is @MainActor)
    self.sourceCounts = result.0 ?? []
    self.sessions = (result.1 ?? []).filter { $0.messageCount > 0 }
    self.dbSize = result.2 ?? 0
}
```

Note: PopoverView timeline is capped at 15 items (`prefix(15)`). `LazyVStack` is unnecessary for this count — keep `VStack`.

**Acceptance:** Popover opens instantly; data fills in within ~50ms without blocking animation.

---

## 2. SessionListView — Debounce + Async + State Preservation

**File:** `macos/Engram/Views/SessionListView.swift`

### 2a. Reference Data Caching

**Current:** `(try? db.listProjects()) ?? []` called inline in view body (line 131) — executes on every render via `@MainActor`.

**Change:**
- `@State private var availableProjects: [String] = []`
- `@State private var availableSources: [String] = []`
- Load once in `.task { }` using `readInBackground`
- `MultiSelectPicker` receives cached `@State` arrays
- Initial render shows empty picker until load completes (acceptable — loads in <50ms)

### 2b. Filter onChange Consolidation + Debounce

**Current:** 7 `.onChange` handlers (groupingMode, selectedSourcesStr, selectedProjectsStr, agentFilterMode, sortField, sortAsc, showingTrash) each independently call `Task { await loadGroups() }`. `loadGroups()` is already async but its DB calls run on `@MainActor`.

**Change:**
- Compute `filterFingerprint: String` from all 7 filter values
- Single `.onChange(of: filterFingerprint)` with 300ms debounce:

```swift
@State private var filterTask: Task<Void, Never>?

private var filterFingerprint: String {
    "\(groupingMode)-\(selectedSourcesStr)-\(selectedProjectsStr)-\(agentFilterMode)-\(sortField)-\(sortAsc)-\(showingTrash)"
}

.onChange(of: filterFingerprint) {
    filterTask?.cancel()
    filterTask = Task {
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        await loadGroups()
    }
}
```

### 2c. loadGroups Uses readInBackground

**Current:** `loadGroups()` is already `async` but calls `db.listGroups()` which is `@MainActor`-isolated.

**Change:** Refactor the DB query inside `loadGroups()` to use `readInBackground`, so the actual SQLite work runs off the main thread.

### 2d. Preserve Expanded Groups (Selective)

**Current:** 4 of 7 onChange handlers clear `expandedGroups` (groupingMode, selectedSourcesStr, selectedProjectsStr, agentFilterMode).

**Change:**
- For `groupingMode` changes: **keep clearing** — group keys fundamentally change (project names vs source names), intersection is meaningless
- For the other 3 (sources, projects, agentFilter): intersect `expandedGroups` with new group keys instead of clearing

```swift
// After loadGroups completes:
if groupingModeChanged {
    expandedGroups = []
} else {
    let newKeys = Set(groups.map(\.id))
    expandedGroups = expandedGroups.filter { newKeys.contains($0) }
}
```

**Acceptance:** Switching filters feels instant; no cascading DB queries; expanded groups persist where meaningful.

---

## 3. TimelineView — Static Formatters + Async

**File:** `macos/Engram/Views/TimelineView.swift`

### 3a. Static DateFormatters

**Current:** `formatDateHeader()` (TimelineView, line 164), `timeString()` (TimelineSessionRow, line 219), and `groupSessionsByDate()` (line 131) each create new DateFormatter instances per call. ~50 sessions = ~100 formatter allocations per render.

**Change:** Static formatters on each struct that needs them:

```swift
// On TimelineView
private static let isoFormatter: ISO8601DateFormatter = { ... }()
private static let headerFormatter: DateFormatter = { ... }() // yyyy-MM-dd EEEE

// On TimelineSessionRow
private static let isoFormatter: ISO8601DateFormatter = { ... }()
private static let timeFormatter: DateFormatter = { ... }() // HH:mm
```

### 3b. Projects Async Load

**Current:** `(try? db.listProjects())` inline in body (line 34).

**Change:** `@State private var availableProjects: [String] = []` + load in `.task { }` using `readInBackground`.

### 3c. ~~Incremental Group Merge~~ — DROPPED

Originally proposed incremental merge for `groupSessionsByDate()` after `loadMore()`. Dropped: for typical page size of 50, linear rebuild is microseconds. Complexity of edge cases (day boundaries, timezone) not justified.

**Acceptance:** Scrolling timeline is smooth; no formatter allocation spikes.

---

## 4. SearchView — Cache + Timeout

**File:** `macos/Engram/Views/SearchView.swift`

### 4a. Cache webPort

**Current:** Computed property reads `settings.json` from disk on every access.

**Change:** `@State private var webPort: Int?`, load once in `.task { }`.

### 4b. Network Timeout

**Current:** No explicit timeout. Default URLSession timeout ~300s.

**Change:** `timeoutIntervalForRequest = 5` for status checks, `15` for search queries.

### 4c. FTS Fallback Off Main Thread

**Current:** Catch block calls `db.search(query:)` inside `MainActor.run {}`, blocking main thread.

**Change:** Move `db.search()` call outside `MainActor.run`, use `readInBackground`.

**Acceptance:** Search never hangs; disk I/O only on first appear.

---

## 5. SessionDetailView — DROPPED

~~Loading state indicator~~ — Already implemented: `@State private var isLoadingMessages = false` (line 53), `ProgressView` shown when true (lines 95-98), set in `.task(id:)` (lines 144-152). No changes needed.

---

## 6. Bonus: Synchronous Write Operations

**File:** `macos/Engram/Views/SessionListView.swift`

`hideEmptySessions()` (line 242) is a synchronous DB write in a button handler on main thread. Wrap in `Task { }` to avoid blocking.

---

## Scope Exclusions

- No pagination rework (approach C) — deferred
- No incremental group merge — dropped after review (negligible benefit)
- No context menu optimization — low impact
- No startup progress indicator — not a frame drop issue
- No DB index changes — Node.js already creates indexes
- No SessionDetailView changes — already well-optimized

---

## Files Changed

| File | Changes |
|------|---------|
| Database.swift | Add `nonisolated readInBackground()` method |
| PopoverView.swift | async loadData via readInBackground |
| SessionListView.swift | @State caches, debounce, readInBackground loadGroups, selective expand preserve |
| TimelineView.swift | static formatters, async projects load |
| SearchView.swift | cache webPort, timeout, async FTS fallback |

## Testing

- Manual: open popover, switch filters rapidly, scroll timeline, search
- Instruments: Time Profiler to verify no main thread blocking > 16ms
- No unit test changes needed (all changes are View-layer)
