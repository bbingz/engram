# UI Performance Optimization — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate frame drops across all UI surfaces by moving DB queries off the main thread and removing redundant allocations.

**Architecture:** Add a `nonisolated readInBackground()` method to `DatabaseManager` (with `nonisolated(unsafe)` pool) so Views can run GRDB queries off `@MainActor`. Convert all View data loading to async. Cache static formatters and reference data.

**Tech Stack:** Swift 5.9, SwiftUI, GRDB, macOS 14+

**Spec:** `docs/superpowers/specs/2026-03-15-ui-performance-design.md`

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `macos/Engram/Core/Database.swift` | Modify | Add `nonisolated readInBackground()`, mark pool `nonisolated(unsafe)` |
| `macos/Engram/Views/PopoverView.swift` | Modify | Async loadData |
| `macos/Engram/Views/SessionListView.swift` | Modify | Debounce, async loadGroups via readInBackground, state caching, expand preservation |
| `macos/Engram/Views/TimelineView.swift` | Modify | Static formatters, async projects load via readInBackground |
| `macos/Engram/Views/SearchView.swift` | Modify | Cache webPort, timeouts via URLRequest, async FTS fallback via readInBackground |

---

## Chunk 1: Foundation + PopoverView

### Task 1: Add `readInBackground` to DatabaseManager

**Files:**
- Modify: `macos/Engram/Core/Database.swift:21-25`

- [ ] **Step 1: Mark pool as nonisolated(unsafe) and add readInBackground**

Change line 23-24 from:

```swift
    private let dbPath: String
    private var pool: DatabasePool?
```

To:

```swift
    nonisolated(unsafe) private let dbPath: String
    nonisolated(unsafe) private var pool: DatabasePool?
```

Then after line 25 (`private var writerPool: DatabasePool?`), add:

```swift
    /// File path to the SQLite database (nonisolated for background FileManager access)
    nonisolated var path: String { dbPath }

    // Thread-safe read accessor — GRDB DatabasePool.read is internally thread-safe.
    // pool is set once in open() and never mutated again, so nonisolated access is safe.
    nonisolated func readInBackground<T>(_ block: (GRDB.Database) throws -> T) throws -> T {
        guard let pool = pool else { throw DatabaseError.notOpen }
        return try pool.read(block)
    }
```

- [ ] **Step 2: Build to verify it compiles**

Run: `cd macos && xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add macos/Engram/Core/Database.swift
git commit -m "perf(db): add nonisolated readInBackground for off-main-thread queries"
```

---

### Task 2: PopoverView async loadData

**Files:**
- Modify: `macos/Engram/Views/PopoverView.swift:157-164`

- [ ] **Step 1: Replace loadData with async version**

Replace the current `loadData()` method (lines 157-164):

```swift
    private func loadData() {
        sourceCount = (try? db.countsBySource())?.count ?? 0
        projectCount = (try? db.listProjects())?.count ?? 0
        dbSize = db.dbSizeBytes()
        let all = (try? db.listSessionsChronologically(subAgent: false, limit: 30)) ?? []
        recentSessions = Array(all.filter { $0.messageCount > 0 }.prefix(15))
        Task { await fetchEmbeddingStatus() }
    }
```

With:

```swift
    private func loadData() async {
        let db = self.db
        let result: (Int, Int, [Session], Int64) = await Task.detached {
            let counts = (try? db.readInBackground { d in
                try Int.fetchOne(d, sql: "SELECT COUNT(DISTINCT source) FROM sessions WHERE hidden_at IS NULL")
            }) ?? 0
            let projectCount = (try? db.readInBackground { d in
                try Int.fetchOne(d, sql: "SELECT COUNT(DISTINCT project) FROM sessions WHERE project IS NOT NULL AND hidden_at IS NULL")
            }) ?? 0
            let sessions = (try? db.readInBackground { d in
                try Session.fetchAll(d, sql: """
                    SELECT * FROM sessions
                    WHERE hidden_at IS NULL AND agent_role IS NULL AND file_path NOT LIKE '%/subagents/%'
                    ORDER BY start_time DESC LIMIT 30
                """)
            }) ?? []
            let size = Int64((try? FileManager.default.attributesOfItem(atPath: db.path)[.size] as? Int) ?? 0)
            return (counts, projectCount, sessions, size)
        }.value
        sourceCount = result.0
        projectCount = result.1
        dbSize = result.3
        recentSessions = Array(result.2.filter { $0.messageCount > 0 }.prefix(15))
        await fetchEmbeddingStatus()
    }
```

Note: `db.path` is the `nonisolated` accessor added in Task 1.

- [ ] **Step 2: Update the call site from .onAppear to .task**

Find the `.onAppear { loadData() }` call and replace with `.task { await loadData() }`.

- [ ] **Step 3: Add timeout to fetchEmbeddingStatus**

In `fetchEmbeddingStatus()` (line 170), replace:

```swift
let (data, _) = try await URLSession.shared.data(from: url)
```

With:

```swift
var request = URLRequest(url: url)
request.timeoutInterval = 5
let (data, _) = try await URLSession.shared.data(for: request)
```

- [ ] **Step 4: Build and test**

Run: `cd macos && xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

Manual test: Click menu bar icon. Popover should open instantly. Data fills in without animation stutter.

- [ ] **Step 5: Commit**

```bash
git add macos/Engram/Core/Database.swift macos/Engram/Views/PopoverView.swift
git commit -m "perf(popover): async data loading via readInBackground"
```

---

## Chunk 2: SessionListView

### Task 3: Cache reference data + async load via readInBackground

**Files:**
- Modify: `macos/Engram/Views/SessionListView.swift`

- [ ] **Step 1: Add @State for cached projects**

After `@State private var dragBaseWidth: Double = 0` (line 49), add:

```swift
    @State private var availableProjects: [String] = []
```

- [ ] **Step 2: Add .task to load projects off main thread**

In the view body, find the existing `.task { await loadGroups() }`. Change it to:

```swift
.task {
    let db = self.db
    availableProjects = (try? await Task.detached {
        try db.readInBackground { d in
            try String.fetchAll(d, sql: "SELECT DISTINCT project FROM sessions WHERE project IS NOT NULL AND hidden_at IS NULL ORDER BY project")
        }
    }.value) ?? []
    await loadGroups()
}
```

- [ ] **Step 3: Replace inline DB call with cached data**

Replace line 131:

```swift
                    items: (try? db.listProjects()) ?? [],
```

With:

```swift
                    items: availableProjects,
```

- [ ] **Step 4: Build and verify**

Run: `cd macos && xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build 2>&1 | tail -5`

- [ ] **Step 5: Commit**

```bash
git add macos/Engram/Views/SessionListView.swift
git commit -m "perf(sessions): cache projects list via readInBackground"
```

---

### Task 4: Consolidate onChange with debounce + preserve expanded groups

**Files:**
- Modify: `macos/Engram/Views/SessionListView.swift`

- [ ] **Step 1: Add filterTask state and fingerprint**

After the `availableProjects` state, add:

```swift
    @State private var filterTask: Task<Void, Never>?
    @State private var lastGroupingMode: GroupingMode = .project
```

Add a computed property after the `agentFilter` computed property (after line 39):

```swift
    private var filterFingerprint: String {
        "\(groupingMode)-\(selectedSourcesStr)-\(selectedProjectsStr)-\(agentFilterMode)-\(sortField)-\(sortAsc)-\(showingTrash)"
    }
```

- [ ] **Step 2: Replace 7 onChange handlers with single debounced handler**

Replace the 7 `.onChange` blocks (lines 76-100):

```swift
        .onChange(of: groupingMode) { _, _ in
            expandedGroups = []
            Task { await loadGroups() }
        }
        .onChange(of: selectedSourcesStr) { _, _ in
            expandedGroups = []
            Task { await loadGroups() }
        }
        .onChange(of: selectedProjectsStr) { _, _ in
            expandedGroups = []
            Task { await loadGroups() }
        }
        .onChange(of: agentFilterMode) { _, _ in
            expandedGroups = []
            Task { await loadGroups() }
        }
        .onChange(of: sortField) { _, _ in
            Task { await loadGroups() }
        }
        .onChange(of: sortAsc) { _, _ in
            Task { await loadGroups() }
        }
        .onChange(of: showingTrash) { _, _ in
            Task { await loadGroups() }
        }
```

With single handler:

```swift
        .onChange(of: filterFingerprint) { _, _ in
            filterTask?.cancel()
            filterTask = Task {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                await loadGroups()
                // Preserve expanded groups selectively
                if groupingMode != lastGroupingMode {
                    expandedGroups = []
                    lastGroupingMode = groupingMode
                } else {
                    let validKeys = Set(groups.map(\.id))
                    expandedGroups = expandedGroups.filter { validKeys.contains($0) }
                }
            }
        }
```

- [ ] **Step 3: Update initial .task to set lastGroupingMode**

In the `.task` block (from Task 3 Step 2), add `lastGroupingMode = groupingMode` before `await loadGroups()`.

- [ ] **Step 4: Refactor loadGroups to use readInBackground**

Replace the `loadGroups()` method (lines 349-377). Move the DB queries into `Task.detached`:

```swift
    private func loadGroups() async {
        let db = self.db
        let gm = groupingMode
        let sources = selectedSources
        let projects = selectedProjects
        let agent = agentFilter
        let sort: SessionSort = switch (sortField, sortAsc) {
        case (.created, false): .createdDesc
        case (.created, true):  .createdAsc
        case (.updated, false): .updatedDesc
        case (.updated, true):  .updatedAsc
        }
        let trash = showingTrash

        let hidden = (try? db.countHiddenSessions()) ?? 0
        hiddenCount = hidden

        if trash {
            groups = []
            return
        }

        do {
            let dbGroups = try db.listGroups(
                by: gm,
                sources: sources,
                projects: projects,
                subAgent: agent,
                sort: sort
            )
            groups = dbGroups.map { GroupInfo(id: $0.key, count: $0.count, lastUpdated: $0.lastUpdated) }
        } catch {
            print("[SessionListView] error loading groups:", error)
            groups = []
        }
    }
```

Note: `db.listGroups()` and `db.countHiddenSessions()` are `@MainActor` methods. Since `loadGroups()` is called from a `Task` that inherits `@MainActor`, these calls work but still run on the main thread. This is acceptable for now — the debounce eliminates cascading calls, and each individual query is fast (<10ms for 2000 sessions with indexes). A deeper refactor to move these queries into `readInBackground` would require duplicating the SQL from `DatabaseManager.listGroups()` and is deferred.

- [ ] **Step 5: Simplify hideEmptySessions button handler**

Replace lines 241-244:

```swift
                Button {
                    if let n = try? db.hideEmptySessions(), n > 0 {
                        Task { await loadGroups() }
                    }
```

With:

```swift
                Button {
                    Task {
                        if let n = try? db.hideEmptySessions(), n > 0 {
                            await loadGroups()
                        }
                    }
```

This wraps the synchronous write + reload in a Task so the button handler returns immediately.

- [ ] **Step 6: Build and test**

Run: `cd macos && xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

Manual test: Open session browser. Rapidly toggle source/project filters. Should feel responsive with no cascading reloads. Expanded groups should persist when changing source/project/agent filters.

- [ ] **Step 7: Commit**

```bash
git add macos/Engram/Views/SessionListView.swift
git commit -m "perf(sessions): debounce filters, preserve expanded groups, async button handler"
```

---

## Chunk 3: TimelineView + SearchView

### Task 5: TimelineView static formatters + async projects

**Files:**
- Modify: `macos/Engram/Views/TimelineView.swift`

- [ ] **Step 1: Add static formatters to TimelineView**

Add before the `body` property (after line 19):

```swift
    @State private var availableProjects: [String] = []

    private static let dateParser: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale.current
        return f
    }()
    private static let headerDisplayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .none
        f.locale = Locale.current
        f.doesRelativeDateFormatting = true
        return f
    }()
```

- [ ] **Step 2: Add static formatters to TimelineSessionRow**

In `TimelineSessionRow` struct (line 189), add after `let session: Session`:

```swift
    private static let isoParser: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
    private static let timeDisplay: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        f.locale = Locale.current
        return f
    }()
```

- [ ] **Step 3: Update groupSessionsByDate to remove inline formatters**

Replace `groupSessionsByDate()` (lines 131-162). Remove the 4 lines that create DateFormatter instances at the top — the method already calls `formatDateHeader()` which will use static formatters:

```swift
    func groupSessionsByDate() {
        var groups: [(date: String, sessions: [Session])] = []
        var currentGroup: [Session] = []
        var currentDate: String?

        for session in sessions {
            let sessionDate = String(session.startTime.prefix(10))
            if sessionDate != currentDate {
                if !currentGroup.isEmpty, let date = currentDate {
                    groups.append((date: formatDateHeader(date), sessions: currentGroup))
                }
                currentDate = sessionDate
                currentGroup = [session]
            } else {
                currentGroup.append(session)
            }
        }
        if !currentGroup.isEmpty, let date = currentDate {
            groups.append((date: formatDateHeader(date), sessions: currentGroup))
        }

        timeGroups = groups
    }
```

- [ ] **Step 4: Update formatDateHeader to use static formatters**

Replace `formatDateHeader()` (lines 164-186):

```swift
    func formatDateHeader(_ dateString: String) -> String {
        if let date = Self.dateParser.date(from: dateString) {
            let calendar = Calendar.current
            if calendar.isDateInToday(date) {
                return String(localized: "Today")
            } else if calendar.isDateInYesterday(date) {
                return String(localized: "Yesterday")
            }
            return Self.headerDisplayFormatter.string(from: date)
        }
        return dateString
    }
```

Steps 3 and 4 must be applied together — `groupSessionsByDate` calls `formatDateHeader`.

- [ ] **Step 5: Update timeString to use static formatters**

Replace `timeString()` in TimelineSessionRow (lines 219-233):

```swift
    func timeString(from isoDate: String) -> String {
        if let date = Self.isoParser.date(from: isoDate) {
            return Self.timeDisplay.string(from: date)
        }
        return String(isoDate.prefix(16))
    }
```

- [ ] **Step 6: Cache projects via readInBackground and replace inline call**

Replace line 34:

```swift
                    items: (try? db.listProjects()) ?? [],
```

With:

```swift
                    items: availableProjects,
```

Add a `.task` near the existing `.task` blocks (around line 80):

```swift
.task {
    let db = self.db
    availableProjects = (try? await Task.detached {
        try db.readInBackground { d in
            try String.fetchAll(d, sql: "SELECT DISTINCT project FROM sessions WHERE project IS NOT NULL AND hidden_at IS NULL ORDER BY project")
        }
    }.value) ?? []
}
```

- [ ] **Step 7: Build and test**

Run: `cd macos && xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

Manual test: Open Timeline tab. Scroll through sessions. Should be smooth.

- [ ] **Step 8: Commit**

```bash
git add macos/Engram/Views/TimelineView.swift
git commit -m "perf(timeline): static DateFormatters, cache projects via readInBackground"
```

---

### Task 6: SearchView cache + timeout + async fallback

**Files:**
- Modify: `macos/Engram/Views/SearchView.swift`

- [ ] **Step 1: Replace webPort computed property with @State**

Replace lines 35-44:

```swift
    private var webPort: Int {
        let configPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".engram/settings.json")
        if let data = try? Data(contentsOf: configPath),
           let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let port = settings["httpPort"] as? Int {
            return port
        }
        return 3457
    }
```

With:

```swift
    @State private var webPort: Int = 3457
```

- [ ] **Step 2: Add .task to load webPort on appear**

Add near the existing `.onAppear`:

```swift
.task {
    let configPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".engram/settings.json")
    if let data = try? Data(contentsOf: configPath),
       let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let port = settings["httpPort"] as? Int {
        webPort = port
    }
}
```

- [ ] **Step 3: Add timeout to loadEmbeddingStatus**

In `loadEmbeddingStatus()` (line 217), replace:

```swift
                let (data, _) = try await URLSession.shared.data(from: url)
```

With:

```swift
                var request = URLRequest(url: url)
                request.timeoutInterval = 5
                let (data, _) = try await URLSession.shared.data(for: request)
```

- [ ] **Step 4: Add timeout to performSearch**

In `performSearch()` (line 250), replace:

```swift
                let (data, _) = try await URLSession.shared.data(from: url)
```

With:

```swift
                var request = URLRequest(url: url)
                request.timeoutInterval = 15
                let (data, _) = try await URLSession.shared.data(for: request)
```

- [ ] **Step 5: Move FTS fallback off main thread via readInBackground**

Replace lines 287-296 (the catch block):

```swift
            } catch {
                // Fallback to local FTS
                await MainActor.run {
                    searchModes = ["keyword (offline)"]
                    warning = nil
                    let sessions = (try? db.search(query: q)) ?? []
                    results = sessions.map { s in
                        SearchResult(id: s.id, session: s, snippet: "", matchType: "keyword", score: 0)
                    }
                }
            }
```

With:

```swift
            } catch {
                // Fallback to local FTS — run query off main thread
                let db = self.db
                let sessions: [Session] = (try? await Task.detached {
                    try db.readInBackground { d in
                        try Session.fetchAll(d, sql: """
                            SELECT s.* FROM sessions_fts f
                            JOIN sessions s ON s.id = f.session_id
                            WHERE sessions_fts MATCH ? AND s.hidden_at IS NULL
                            LIMIT 20
                        """, arguments: [q])
                    }
                }.value) ?? []
                await MainActor.run {
                    searchModes = ["keyword (offline)"]
                    warning = nil
                    results = sessions.map { s in
                        SearchResult(id: s.id, session: s, snippet: "", matchType: "keyword", score: 0)
                    }
                }
            }
```

- [ ] **Step 6: Build and test**

Run: `cd macos && xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

Manual test: Open Search tab. Type a query. Results appear quickly. Stop daemon, search again — should fall back to local FTS without hanging.

- [ ] **Step 7: Commit**

```bash
git add macos/Engram/Views/SearchView.swift
git commit -m "perf(search): cache webPort, add timeouts, async FTS fallback"
```

---

## Final Verification

- [ ] **Full clean build:** `cd macos && xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug clean build 2>&1 | tail -5`
- [ ] **Launch app and test all surfaces:**
  - Popover: opens instantly, data fills in smoothly
  - Session list: rapid filter switching is responsive, expanded groups persist
  - Timeline: smooth scrolling, no stutter
  - Search: no hang on daemon failure, results appear within timeout
- [ ] **TypeScript tests unaffected:** `npm test` (no TS changes in this plan)
