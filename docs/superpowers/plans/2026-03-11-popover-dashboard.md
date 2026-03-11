# Popover Dashboard Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the menu bar popover with a lightweight dashboard showing service status, stats, and recent timeline.

**Architecture:** New `PopoverView.swift` replaces `ContentView` in the popover (ContentView stays for the standalone window). PopoverView uses existing `DatabaseManager` methods + one new `dbSizeBytes()` method. Embedding status fetched via HTTP from daemon.

**Tech Stack:** SwiftUI, GRDB (read-only), URLSession

**Spec:** `docs/superpowers/specs/2026-03-11-popover-dashboard-design.md`

---

## File Structure

| File | Action | Responsibility |
|------|--------|---------------|
| `macos/Engram/Views/PopoverView.swift` | Create | Dashboard view: header, status, stats, timeline |
| `macos/Engram/Core/Database.swift` | Modify | Add `dbSizeBytes()` method |
| `macos/Engram/MenuBarController.swift` | Modify | Use PopoverView, resize to 400x420 |

---

### Task 1: Add `dbSizeBytes()` to DatabaseManager

**Files:**
- Modify: `macos/Engram/Core/Database.swift`

- [ ] **Step 1: Add dbSizeBytes method**

Add after the existing `stats()` method (~line 260):

```swift
func dbSizeBytes() -> Int64 {
    guard let path = dbPath else { return 0 }
    return (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
}
```

Note: `dbPath` is the path passed to `open(at:)`. Check how it's stored — if not stored as a property, extract it from the GRDB pool or store it during `open()`.

- [ ] **Step 2: Verify dbPath is accessible**

Read `Database.swift` to check if the db path is stored. If `open(at:)` doesn't save the path, add a `private(set) var dbPath: String?` property and set it in `open()`.

- [ ] **Step 3: Build to verify compilation**

Run: `cd macos && xcodebuild -project Engram.xcodeproj -scheme Engram build 2>&1 | tail -5`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 4: Commit**

```bash
git add macos/Engram/Core/Database.swift
git commit -m "feat(macos): add dbSizeBytes() to DatabaseManager"
```

---

### Task 2: Create PopoverView

**Files:**
- Create: `macos/Engram/Views/PopoverView.swift`

- [ ] **Step 1: Create PopoverView with header section**

```swift
// macos/Engram/Views/PopoverView.swift
import SwiftUI

struct PopoverView: View {
    @EnvironmentObject var db: DatabaseManager
    @EnvironmentObject var indexer: IndexerProcess

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerSection
            statsSection
            timelineSection
            footerSection
        }
        .padding(16)
        .frame(width: 400)
        .onAppear { loadData() }
    }
}
```

- [ ] **Step 2: Implement header with status indicators**

The header has two rows:
- Row 1: "Engram" title + settings gear button
- Row 2: Status dots for Web, MCP, Embedding

Status logic:
- **Web**: green if `indexer.port != nil`, show port number
- **MCP**: green if `indexer.status.isRunning`
- **Embedding**: fetch from `/api/search/status` — green if complete, yellow+% if in progress, gray circle if unavailable

```swift
private var headerSection: some View {
    VStack(alignment: .leading, spacing: 4) {
        HStack {
            Text("Engram").font(.headline)
            Spacer()
            Button { NotificationCenter.default.post(name: .openSettings, object: nil) } label: {
                Image(systemName: "gearshape").foregroundStyle(.secondary)
            }.buttonStyle(.plain)
        }
        HStack(spacing: 10) {
            statusDot(color: indexer.port != nil ? .green : .red,
                      label: indexer.port.map { "Web :\($0)" } ?? "Web")
            statusDot(color: indexer.status.isRunning ? .green : .red,
                      label: "MCP")
            embeddingStatus
        }.font(.caption2)
    }
}
```

- [ ] **Step 3: Implement stats section (2x2 grid)**

```swift
@State private var sourceCount = 0
@State private var projectCount = 0
@State private var dbSize: Int64 = 0

private var statsSection: some View {
    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
        GridRow {
            statRow("Sessions", "\(indexer.totalSessions)")
            statRow("Sources", "\(sourceCount)")
        }
        GridRow {
            statRow("Projects", "\(projectCount)")
            statRow("DB Size", formattedSize(dbSize))
        }
    }
    .font(.caption)
    .padding(10)
    .background(Color(.secondarySystemFill).opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
}
```

- [ ] **Step 4: Implement timeline section**

Use `db.listSessionsChronologically(limit: 15)` and group by date (Today / Yesterday / date string).

```swift
@State private var recentSessions: [Session] = []

private var timelineSection: some View {
    VStack(alignment: .leading, spacing: 2) {
        ForEach(groupedByDate(recentSessions), id: \.key) { group in
            Text(group.key)
                .font(.caption2).fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .padding(.top, group.key == groupedByDate(recentSessions).first?.key ? 0 : 6)
            ForEach(group.sessions) { session in
                timelineRow(session)
            }
        }
    }
}

private func timelineRow(_ session: Session) -> some View {
    HStack(spacing: 6) {
        Circle()
            .fill(SourceDisplay.color(for: session.source))
            .frame(width: 4, height: 4)
        Text(SourceDisplay.label(for: session.source))
            .font(.caption2)
            .foregroundStyle(SourceDisplay.color(for: session.source))
            .frame(width: 58, alignment: .leading)
        Text(session.displayTitle)
            .font(.caption)
            .lineLimit(1)
            .truncationMode(.tail)
        Spacer()
        Text(relativeTime(session.startTime))
            .font(.caption2)
            .foregroundStyle(.secondary)
    }
}
```

- [ ] **Step 5: Implement footer with "Open Window" link**

```swift
private var footerSection: some View {
    HStack {
        Spacer()
        Button("Open Window →") {
            NotificationCenter.default.post(name: .openWindow, object: nil)
        }
        .font(.caption)
        .buttonStyle(.plain)
        .foregroundStyle(.blue)
        Spacer()
    }
}
```

- [ ] **Step 6: Implement embedding status fetch**

Reuse the same pattern from `SearchView.swift`:

```swift
@State private var embeddingAvailable = false
@State private var embeddingProgress: Int?

private var embeddingStatus: some View {
    Group {
        if !embeddingAvailable && embeddingProgress == nil {
            statusDot(color: .secondary, label: "Embedding", hollow: true)
        } else if let pct = embeddingProgress, pct < 100 {
            statusDot(color: .orange, label: "Embedding \(pct)%")
        } else {
            statusDot(color: .green, label: "Embedding")
        }
    }
}

private func fetchEmbeddingStatus() async {
    let port = indexer.port ?? 3457
    guard let url = URL(string: "http://127.0.0.1:\(port)/api/search/status") else { return }
    do {
        let (data, _) = try await URLSession.shared.data(from: url)
        let status = try JSONDecoder().decode(EmbeddingStatusResponse.self, from: data)
        embeddingAvailable = status.available
        if status.available, let p = status.progress, p < 100 {
            embeddingProgress = p
        } else {
            embeddingProgress = nil
        }
    } catch {
        embeddingAvailable = false
        embeddingProgress = nil
    }
}
```

Reuse `EmbeddingStatusResponse` from SearchView.swift — move it to a shared location or re-declare locally.

- [ ] **Step 7: Implement helper functions**

```swift
private func loadData() {
    sourceCount = (try? db.countsBySource())?.count ?? 0
    projectCount = (try? db.listProjects())?.count ?? 0
    dbSize = db.dbSizeBytes()
    recentSessions = (try? db.listSessionsChronologically(limit: 15)) ?? []
    Task { await fetchEmbeddingStatus() }
}

private func statusDot(color: Color, label: String, hollow: Bool = false) -> some View {
    HStack(spacing: 3) {
        if hollow {
            Circle().strokeBorder(color, lineWidth: 1).frame(width: 5, height: 5)
        } else {
            Circle().fill(color).frame(width: 5, height: 5)
        }
        Text(label)
    }
}

private struct DateGroup: Identifiable {
    let key: String
    let sessions: [Session]
    var id: String { key }
}

private func groupedByDate(_ sessions: [Session]) -> [DateGroup] {
    let cal = Calendar.current
    var groups: [(String, [Session])] = []
    var currentKey = ""
    var currentGroup: [Session] = []
    for s in sessions {
        let dateStr = s.startTime?.prefix(10).description ?? ""
        let key: String
        if let date = ISO8601DateFormatter().date(from: s.startTime ?? "") ?? dateFromPrefix(dateStr) {
            if cal.isDateInToday(date) { key = "TODAY" }
            else if cal.isDateInYesterday(date) { key = "YESTERDAY" }
            else { key = dateStr }
        } else { key = dateStr }
        if key != currentKey {
            if !currentGroup.isEmpty { groups.append((currentKey, currentGroup)) }
            currentKey = key; currentGroup = [s]
        } else { currentGroup.append(s) }
    }
    if !currentGroup.isEmpty { groups.append((currentKey, currentGroup)) }
    return groups.map { DateGroup(key: $0.0, sessions: $0.1) }
}

private func dateFromPrefix(_ s: String) -> Date? {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.date(from: s)
}

private func relativeTime(_ ts: String?) -> String {
    guard let ts, let d = ISO8601DateFormatter().date(from: ts) else { return "" }
    let secs = -d.timeIntervalSinceNow
    if secs < 60 { return "now" }
    if secs < 3600 { return "\(Int(secs / 60))m" }
    if secs < 86400 { return "\(Int(secs / 3600))h" }
    return "\(Int(secs / 86400))d"
}

private func formattedSize(_ bytes: Int64) -> String {
    if bytes < 1024 { return "\(bytes) B" }
    if bytes < 1_048_576 { return String(format: "%.1f KB", Double(bytes) / 1024) }
    return String(format: "%.1f MB", Double(bytes) / 1_048_576)
}
```

- [ ] **Step 8: Build to verify compilation**

Run: `cd macos && xcodebuild -project Engram.xcodeproj -scheme Engram build 2>&1 | tail -5`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 9: Commit**

```bash
git add macos/Engram/Views/PopoverView.swift
git commit -m "feat(macos): add PopoverView dashboard"
```

---

### Task 3: Wire PopoverView into MenuBarController

**Files:**
- Modify: `macos/Engram/MenuBarController.swift`

- [ ] **Step 1: Change popover content and size**

In `MenuBarController.init()`, change:

```swift
// Before:
popover.contentSize = NSSize(width: 760, height: 640)
popover.contentViewController = NSHostingController(
    rootView: ContentView()
        .environmentObject(db)
        .environmentObject(indexer)
)

// After:
popover.contentSize = NSSize(width: 400, height: 420)
popover.contentViewController = NSHostingController(
    rootView: PopoverView()
        .environmentObject(db)
        .environmentObject(indexer)
)
```

- [ ] **Step 2: Add .openWindow notification listener**

PopoverView's "Open Window →" button posts `.openWindow`. Add a listener in `MenuBarController.init()` alongside the existing `.openSettings` listener:

```swift
NotificationCenter.default.addObserver(
    self, selector: #selector(openWindow),
    name: .openWindow, object: nil
)
```

And add the notification name extension:

```swift
extension Notification.Name {
    static let openWindow = Notification.Name("openWindow")
}
```

Check if `.openSettings` is already declared somewhere — add `.openWindow` in the same place.

- [ ] **Step 3: Build and test**

Run: `cd macos && xcodebuild -project Engram.xcodeproj -scheme Engram build 2>&1 | tail -5`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 4: Commit**

```bash
git add macos/Engram/MenuBarController.swift
git commit -m "feat(macos): wire PopoverView into menu bar popover"
```

---

### Task 4: Regenerate Xcode project and verify

- [ ] **Step 1: Regenerate project**

New file `PopoverView.swift` must be included in the Xcode project.

Run: `cd macos && xcodegen generate`

- [ ] **Step 2: Full build**

Run: `cd macos && xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build 2>&1 | tail -5`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Launch and verify**

Kill existing Engram, launch the new build. Click menu bar icon — should show the compact dashboard popover. Double-click should still open the full window with ContentView.

- [ ] **Step 4: Final commit**

```bash
git add macos/project.yml
git commit -m "feat(macos): popover dashboard — compact status + timeline view"
```
