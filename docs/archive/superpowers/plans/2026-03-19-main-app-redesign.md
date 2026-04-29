# Main App Window Redesign — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Redesign Engram's standalone window from a scaled-up PopoverView into a full NavigationSplitView dashboard with 12 pages, a shared component library, and a mixed GRDB + HTTP data layer.

**Architecture:** Phase 1 builds the skeleton serially: model updates → color system → components → data layer → navigation shell → Home dashboard → MenuBarController wiring. Phase 2 builds 11 remaining pages in parallel via subagents. Each page is an independent SwiftUI view in `Views/Pages/` that reads data from `DatabaseManager` (GRDB) or `DaemonClient` (HTTP).

**Tech Stack:** Swift 5.9 / SwiftUI / macOS 14+ / GRDB 6 / NavigationSplitView. TypeScript / Hono (daemon HTTP endpoints). Vitest (TS tests). xcodegen for project generation.

**Spec:** `docs/superpowers/specs/2026-03-19-main-app-redesign-design.md`

---

## File Structure

### New Files (Swift)

| File | Responsibility |
|------|---------------|
| `Models/Screen.swift` | Navigation enum (12 cases + section grouping) |
| `Components/SourceColors.swift` | Unified source→color mapping (replaces SourceDisplay.color + SourceBadge.color) |
| `Components/KPICard.swift` | Large number + label card |
| `Components/SectionHeader.swift` | Icon + title + badge + refresh + trailing action |
| `Components/SourcePill.swift` | Colored source name pill |
| `Components/ProjectBadge.swift` | Project name badge |
| `Components/SessionCard.swift` | Full-width session row for lists |
| `Components/BarChart.swift` | Horizontal bar chart |
| `Components/ActivityChart.swift` | Vertical daily activity bar chart |
| `Components/HeatmapGrid.swift` | Hour-of-day intensity grid |
| `Components/TierBar.swift` | Stacked horizontal tier distribution bar |
| `Components/AlertBanner.swift` | Orange warning banner |
| `Components/EmptyState.swift` | Centered no-data placeholder |
| `Components/SkeletonRow.swift` | Animated loading placeholder |
| `Components/FilterPills.swift` | Selectable time-range pill row |
| `Core/DaemonClient.swift` | HTTP client for daemon API |
| `Views/MainWindowView.swift` | NavigationSplitView shell |
| `Views/SidebarView.swift` | Sidebar with 4 sections + 12 items |
| `Views/Pages/HomeView.swift` | Home dashboard (7 blocks) |
| `Views/Pages/SearchPageView.swift` | Full-page search |
| `Views/Pages/SessionsPageView.swift` | Sessions list with filters |
| `Views/Pages/TimelinePageView.swift` | Date-grouped session timeline |
| `Views/Pages/ActivityView.swift` | Activity analytics |
| `Views/Pages/ProjectsView.swift` | Project browser |
| `Views/Pages/SourcePulseView.swift` | Adapter health dashboard |
| `Views/Pages/SkillsView.swift` | Installed skills browser |
| `Views/Pages/AgentsView.swift` | Agent session browser |
| `Views/Pages/MemoryView.swift` | Memory file browser |
| `Views/Pages/HooksView.swift` | Hook configuration viewer |

### Modified Files (Swift)

| File | Change |
|------|--------|
| `Models/Session.swift` | Add `tier: String?` + `toolMessageCount: Int` properties |
| `Core/Database.swift` | Add 8 dashboard query methods |
| `MenuBarController.swift` | `openWindow()` → create `MainWindowView` instead of `ContentView`; store `DaemonClient` |
| `App.swift` | Create `DaemonClient` in `AppDelegate`, inject via environment |
| `Views/SessionDetailView.swift` | Replace `SourceDisplay.color()` with `SourceColors.color()` |
| `Views/SearchView.swift` | Replace `SourceBadge.color` with `SourceColors.color()` |

### Modified Files (TypeScript)

| File | Change |
|------|--------|
| `src/web.ts` | Add 4 API endpoints: `/api/sources`, `/api/skills`, `/api/memory`, `/api/hooks` |

### xcodegen

| File | Change |
|------|--------|
| `macos/project.yml` | No change needed — xcodegen uses `sources: [{path: Engram}]` which auto-discovers all .swift files in the directory tree |

---

## Phase 1 — Skeleton (Serial)

### Task 1: Session Model Update

**Files:**
- Modify: `macos/Engram/Models/Session.swift:6-40`

- [ ] **Step 1: Add tier and toolMessageCount properties**

Add after `customName` (line 24) and add CodingKeys:

```swift
// In Session struct, after customName:
let tier: String?
let toolMessageCount: Int

// In CodingKeys enum, add:
case tier
case toolMessageCount   = "tool_message_count"
```

The `tier` column already exists in the sessions table (added by session-pipeline-tiering). `tool_message_count` also exists (populated by indexer). Both are nullable in DB but toolMessageCount is Int (GRDB decodes NULL as 0 for Int).

- [ ] **Step 2: Build to verify**

```bash
cd /Users/example/-Code-/coding-memory/macos && xcodegen generate && xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add macos/Engram/Models/Session.swift
git commit -m "feat(macos): add tier and toolMessageCount to Session model"
```

---

### Task 2: SourceColors — Unified Color System

**Files:**
- Create: `macos/Engram/Components/SourceColors.swift`
- Modify: `macos/Engram/Views/SessionDetailView.swift` (SourceDisplay.color)
- Modify: `macos/Engram/Views/SearchView.swift` (SourceBadge.color)

- [ ] **Step 1: Create the Components directory and SourceColors.swift**

```bash
mkdir -p /Users/example/-Code-/coding-memory/macos/Engram/Components
```

```swift
// macos/Engram/Components/SourceColors.swift
import SwiftUI

/// Single source of truth for source → color mapping.
/// Used by Popover (SourceBadge, SourceDisplay) and Main Window (SourcePill, charts).
enum SourceColors {
    static func color(for source: String) -> Color {
        switch source {
        case "claude-code":   return Color(hex: 0x4A8FE7)  // Blue
        case "cursor":        return Color(hex: 0xA855F7)  // Purple
        case "codex":         return Color(hex: 0x30D158)  // Green
        case "gemini-cli":    return Color(hex: 0xFF9F0A)  // Orange
        case "windsurf":      return Color(hex: 0xFF453A)  // Red
        case "cline":         return Color(hex: 0x30B0C7)  // Teal
        case "vscode":        return Color(hex: 0x00A1F1)  // Cyan
        case "antigravity":   return Color(hex: 0xFF9F0A)  // Orange (same as gemini)
        case "copilot":       return Color(hex: 0x8E8E93)  // Gray
        case "opencode":      return Color(hex: 0x5856D6)  // Indigo
        case "iflow":         return Color(hex: 0xA855F7)  // Purple
        case "qwen":          return Color(hex: 0x30B0C7)  // Teal
        case "kimi":          return Color(hex: 0xFF6482)  // Pink
        case "minimax":       return Color(hex: 0xFF453A)  // Red
        case "lobsterai":     return Color(hex: 0xFFCC00)  // Yellow
        default:              return Color(hex: 0x8E8E93)  // Gray
        }
    }

    static func label(for source: String) -> String {
        switch source {
        case "claude-code":   return "Claude"
        case "codex":         return "Codex"
        case "copilot":       return "Copilot"
        case "gemini-cli":    return "Gemini"
        case "kimi":          return "Kimi"
        case "qwen":          return "Qwen"
        case "minimax":       return "MiniMax"
        case "lobsterai":     return "Lobster AI"
        case "cline":         return "Cline"
        case "cursor":        return "Cursor"
        case "windsurf":      return "Windsurf"
        case "antigravity":   return "Antigravity"
        case "opencode":      return "OpenCode"
        case "iflow":         return "iFlow"
        case "vscode":        return "VS Code"
        default:              return source
        }
    }
}

extension Color {
    init(hex: UInt, opacity: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}
```

- [ ] **Step 2: Refactor SourceDisplay.color in SessionDetailView.swift**

Replace the `SourceDisplay.color(for:)` method body with:

```swift
static func color(for source: String) -> Color {
    SourceColors.color(for: source)
}
```

- [ ] **Step 3: Refactor SourceBadge.color in SearchView.swift**

Replace the `SourceBadge` private `color` computed property body with:

```swift
private var color: Color {
    SourceColors.color(for: source)
}
```

Also replace the `label` computed property:

```swift
private var label: String {
    SourceColors.label(for: source)
}
```

- [ ] **Step 4: Build to verify**

```bash
cd /Users/example/-Code-/coding-memory/macos && xcodegen generate && xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add macos/Engram/Components/SourceColors.swift macos/Engram/Views/SessionDetailView.swift macos/Engram/Views/SearchView.swift
git commit -m "feat(macos): add SourceColors as single source of truth for source colors"
```

---

### Task 3: Screen Enum

**Files:**
- Create: `macos/Engram/Models/Screen.swift`

- [ ] **Step 1: Create Screen.swift**

```swift
// macos/Engram/Models/Screen.swift
import SwiftUI

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

    var title: String {
        switch self {
        case .home:        return "Home"
        case .search:      return "Search"
        case .sessions:    return "Sessions"
        case .timeline:    return "Timeline"
        case .activity:    return "Activity"
        case .projects:    return "Projects"
        case .sourcePulse: return "Source Pulse"
        case .skills:      return "Skills"
        case .agents:      return "Agents"
        case .memory:      return "Memory"
        case .hooks:       return "Hooks"
        case .settings:    return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .home:        return "house"
        case .search:      return "magnifyingglass"
        case .sessions:    return "bubble.left.and.bubble.right"
        case .timeline:    return "chart.bar.xaxis"
        case .activity:    return "bolt"
        case .projects:    return "folder"
        case .sourcePulse: return "antenna.radiowaves.left.and.right"
        case .skills:      return "sparkles"
        case .agents:      return "cpu"
        case .memory:      return "brain"
        case .hooks:       return "link"
        case .settings:    return "gear"
        }
    }

    /// Sidebar sections (Settings excluded — it's pinned to bottom)
    enum Section: String, CaseIterable {
        case overview  = "OVERVIEW"
        case monitor   = "MONITOR"
        case workspace = "WORKSPACE"
        case config    = "CONFIG"

        var screens: [Screen] {
            switch self {
            case .overview:  return [.home, .search]
            case .monitor:   return [.sessions, .timeline, .activity]
            case .workspace: return [.projects, .sourcePulse]
            case .config:    return [.skills, .agents, .memory, .hooks]
            }
        }
    }
}
```

- [ ] **Step 2: Build to verify**

```bash
cd /Users/example/-Code-/coding-memory/macos && xcodegen generate && xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build 2>&1 | tail -5
```

- [ ] **Step 3: Commit**

```bash
git add macos/Engram/Models/Screen.swift
git commit -m "feat(macos): add Screen enum for NavigationSplitView routing"
```

---

### Task 4: Component Library — Layout Components

**Files:**
- Create: `macos/Engram/Components/KPICard.swift`
- Create: `macos/Engram/Components/SectionHeader.swift`
- Create: `macos/Engram/Components/AlertBanner.swift`
- Create: `macos/Engram/Components/EmptyState.swift`
- Create: `macos/Engram/Components/SkeletonRow.swift`
- Create: `macos/Engram/Components/FilterPills.swift`

- [ ] **Step 1: Create KPICard.swift**

```swift
// macos/Engram/Components/KPICard.swift
import SwiftUI

struct KPICard: View {
    let value: String
    let label: String
    var delta: String? = nil
    var deltaPositive: Bool = true

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text(label)
                .font(.caption)
                .foregroundStyle(Color(hex: 0xA0A1A8))
            if let delta {
                Text(delta)
                    .font(.caption2)
                    .foregroundStyle(deltaPositive ? Color(hex: 0x30D158) : Color(hex: 0xFF453A))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.02))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.04), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
```

- [ ] **Step 2: Create SectionHeader.swift**

```swift
// macos/Engram/Components/SectionHeader.swift
import SwiftUI

struct SectionHeader: View {
    let icon: String
    let title: String
    var badge: String? = nil
    var onRefresh: (() -> Void)? = nil
    var trailingAction: (label: String, action: () -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(Color(hex: 0x6E7078))
            Text(title)
                .font(.headline)
                .foregroundStyle(.white)
            if let badge {
                Text(badge)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.06))
                    .clipShape(Capsule())
                    .foregroundStyle(Color(hex: 0xA0A1A8))
            }
            if let onRefresh {
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                        .foregroundStyle(Color(hex: 0x6E7078))
                }
                .buttonStyle(.plain)
            }
            Spacer()
            if let trailing = trailingAction {
                Button(action: trailing.action) {
                    HStack(spacing: 4) {
                        Text(trailing.label)
                        Image(systemName: "chevron.right")
                    }
                    .font(.caption)
                    .foregroundStyle(Color(hex: 0x4A8FE7))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 4)
    }
}
```

- [ ] **Step 3: Create AlertBanner.swift**

```swift
// macos/Engram/Components/AlertBanner.swift
import SwiftUI

struct AlertBanner: View {
    let message: String
    var action: (label: String, action: () -> Void)? = nil

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color(hex: 0xFF9F0A))
            Text(message)
                .font(.callout)
                .foregroundStyle(.white)
            Spacer()
            if let action {
                Button(action: action.action) {
                    HStack(spacing: 4) {
                        Text(action.label)
                        Image(systemName: "chevron.right")
                    }
                    .font(.caption)
                    .foregroundStyle(Color(hex: 0xFF9F0A))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(Color(hex: 0xFF9F0A).opacity(0.1))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(hex: 0xFF9F0A).opacity(0.2), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
```

- [ ] **Step 4: Create EmptyState.swift**

```swift
// macos/Engram/Components/EmptyState.swift
import SwiftUI

struct EmptyState: View {
    let icon: String
    let title: String
    let message: String
    var action: (label: String, action: () -> Void)? = nil

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundStyle(Color(hex: 0x6E7078))
            Text(title)
                .font(.headline)
                .foregroundStyle(.white)
            Text(message)
                .font(.callout)
                .foregroundStyle(Color(hex: 0xA0A1A8))
                .multilineTextAlignment(.center)
            if let action {
                Button(action: action.action) {
                    Text(action.label)
                        .font(.callout)
                        .foregroundStyle(Color(hex: 0x4A8FE7))
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
```

- [ ] **Step 5: Create SkeletonRow.swift**

```swift
// macos/Engram/Components/SkeletonRow.swift
import SwiftUI

struct SkeletonRow: View {
    @State private var shimmer = false

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.white.opacity(0.04))
                .frame(width: 60, height: 20)
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.white.opacity(0.04))
                .frame(height: 16)
            Spacer()
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.white.opacity(0.04))
                .frame(width: 80, height: 14)
        }
        .padding(.vertical, 8)
        .opacity(shimmer ? 0.4 : 1.0)
        .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: shimmer)
        .onAppear { shimmer = true }
    }
}
```

- [ ] **Step 6: Create FilterPills.swift**

```swift
// macos/Engram/Components/FilterPills.swift
import SwiftUI

struct FilterPills: View {
    let options: [String]
    @Binding var selected: String

    var body: some View {
        HStack(spacing: 8) {
            ForEach(options, id: \.self) { option in
                Button(action: { selected = option }) {
                    Text(option)
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(selected == option
                            ? Color(hex: 0x4A8FE7).opacity(0.25)
                            : Color.white.opacity(0.04))
                        .foregroundStyle(selected == option
                            ? Color(hex: 0x6CB4FF)
                            : Color(hex: 0xA0A1A8))
                        .clipShape(Capsule())
                        .overlay(
                            Capsule().stroke(selected == option
                                ? Color(hex: 0x4A8FE7).opacity(0.3)
                                : Color.clear, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }
}
```

- [ ] **Step 7: Build to verify**

```bash
cd /Users/example/-Code-/coding-memory/macos && xcodegen generate && xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build 2>&1 | tail -5
```

- [ ] **Step 8: Commit**

```bash
git add macos/Engram/Components/KPICard.swift macos/Engram/Components/SectionHeader.swift macos/Engram/Components/AlertBanner.swift macos/Engram/Components/EmptyState.swift macos/Engram/Components/SkeletonRow.swift macos/Engram/Components/FilterPills.swift
git commit -m "feat(macos): add layout components — KPICard, SectionHeader, AlertBanner, EmptyState, SkeletonRow, FilterPills"
```

---

### Task 5: Component Library — Data Display Components

**Files:**
- Create: `macos/Engram/Components/SourcePill.swift`
- Create: `macos/Engram/Components/ProjectBadge.swift`
- Create: `macos/Engram/Components/SessionCard.swift`
- Create: `macos/Engram/Components/BarChart.swift`
- Create: `macos/Engram/Components/ActivityChart.swift`
- Create: `macos/Engram/Components/HeatmapGrid.swift`
- Create: `macos/Engram/Components/TierBar.swift`

- [ ] **Step 1: Create SourcePill.swift**

```swift
// macos/Engram/Components/SourcePill.swift
import SwiftUI

struct SourcePill: View {
    let source: String

    var body: some View {
        Text(SourceColors.label(for: source))
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(SourceColors.color(for: source).opacity(0.15))
            .foregroundStyle(SourceColors.color(for: source))
            .clipShape(Capsule())
    }
}
```

- [ ] **Step 2: Create ProjectBadge.swift**

```swift
// macos/Engram/Components/ProjectBadge.swift
import SwiftUI

struct ProjectBadge: View {
    let project: String
    var source: String = ""

    private var displayName: String {
        // Show last path component for readability
        project.split(separator: "/").last.map(String.init) ?? project
    }

    var body: some View {
        Text(displayName)
            .font(.caption2)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(SourceColors.color(for: source).opacity(0.08))
            .foregroundStyle(Color(hex: 0xA0A1A8))
            .clipShape(Capsule())
    }
}
```

- [ ] **Step 3: Create SessionCard.swift**

```swift
// macos/Engram/Components/SessionCard.swift
import SwiftUI

struct SessionCard: View {
    let session: Session
    var onTap: (() -> Void)? = nil

    var body: some View {
        Button(action: { onTap?() }) {
            HStack(spacing: 10) {
                SourcePill(source: session.source)

                Text(session.displayTitle)
                    .font(.callout)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer()

                if let project = session.project {
                    ProjectBadge(project: project, source: session.source)
                }

                Text("\(session.messageCount) msgs")
                    .font(.caption)
                    .foregroundStyle(Color(hex: 0x6E7078))

                Text(relativeTime(session.startTime))
                    .font(.caption)
                    .foregroundStyle(Color(hex: 0x6E7078))
                    .frame(width: 40, alignment: .trailing)

                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(Color(hex: 0x6E7078).opacity(0.5))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.02))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white.opacity(0.04), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func relativeTime(_ iso: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else {
            return ""
        }
        let seconds = Int(-date.timeIntervalSinceNow)
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86400)d"
    }
}
```

- [ ] **Step 4: Create BarChart.swift**

```swift
// macos/Engram/Components/BarChart.swift
import SwiftUI

struct BarChartItem: Identifiable {
    let id = UUID()
    let label: String
    let value: Int
    let color: Color
}

struct BarChart: View {
    let items: [BarChartItem]

    private var maxValue: Int { items.map(\.value).max() ?? 1 }

    var body: some View {
        VStack(spacing: 8) {
            ForEach(items) { item in
                HStack(spacing: 8) {
                    Text(item.label)
                        .font(.caption)
                        .foregroundStyle(Color(hex: 0xA0A1A8))
                        .frame(width: 90, alignment: .trailing)
                    GeometryReader { geo in
                        let width = maxValue > 0
                            ? geo.size.width * CGFloat(item.value) / CGFloat(maxValue)
                            : 0
                        RoundedRectangle(cornerRadius: 3)
                            .fill(item.color.opacity(0.6))
                            .frame(width: max(width, 2), height: 16)
                    }
                    .frame(height: 16)
                    Text("\(item.value)")
                        .font(.caption)
                        .foregroundStyle(Color(hex: 0x6E7078))
                        .frame(width: 50, alignment: .leading)
                }
            }
        }
    }
}
```

- [ ] **Step 5: Create ActivityChart.swift**

```swift
// macos/Engram/Components/ActivityChart.swift
import SwiftUI

struct ActivityChart: View {
    let data: [(date: String, count: Int)]
    var accentColor: Color = Color(hex: 0x4A8FE7)

    private var maxCount: Int { data.map(\.count).max() ?? 1 }

    var body: some View {
        GeometryReader { geo in
            let barWidth = max((geo.size.width - CGFloat(data.count - 1) * 2) / CGFloat(max(data.count, 1)), 2)
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array(data.enumerated()), id: \.offset) { _, entry in
                    let height = maxCount > 0
                        ? geo.size.height * CGFloat(entry.count) / CGFloat(maxCount)
                        : 0
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(
                                LinearGradient(
                                    colors: [accentColor.opacity(0.8), accentColor.opacity(0.3)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(width: barWidth, height: max(height, 1))
                    }
                }
            }
        }
    }
}
```

- [ ] **Step 6: Create HeatmapGrid.swift**

```swift
// macos/Engram/Components/HeatmapGrid.swift
import SwiftUI

struct HeatmapGrid: View {
    let data: [Int]  // 24 values for hours 0-23
    var colorBase: Color = Color(hex: 0x4A8FE7)

    private var maxValue: Int { data.max() ?? 1 }

    private let hourLabels = ["12a", "", "", "3a", "", "", "6a", "", "", "9a", "", "",
                              "12p", "", "", "3p", "", "", "6p", "", "", "9p", "", ""]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 12), spacing: 3) {
                ForEach(0..<24, id: \.self) { hour in
                    let intensity = maxValue > 0 ? Double(data[hour]) / Double(maxValue) : 0
                    RoundedRectangle(cornerRadius: 3)
                        .fill(intensity > 0
                            ? colorBase.opacity(0.15 + intensity * 0.65)
                            : Color.white.opacity(0.02))
                        .frame(height: 24)
                        .overlay(
                            Group {
                                if data[hour] > 0 {
                                    Text("\(data[hour])")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.white.opacity(0.7))
                                }
                            }
                        )
                }
            }
            HStack(spacing: 0) {
                ForEach([0, 3, 6, 9, 12, 15, 18, 21], id: \.self) { hour in
                    Text(hourLabels[hour])
                        .font(.system(size: 9))
                        .foregroundStyle(Color(hex: 0x6E7078))
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }
}
```

- [ ] **Step 7: Create TierBar.swift**

```swift
// macos/Engram/Components/TierBar.swift
import SwiftUI

struct TierBar: View {
    let premium: Int
    let normal: Int
    let lite: Int
    let skip: Int

    private var total: Int { premium + normal + lite + skip }

    private let tierColors: [(String, Color)] = [
        ("premium", Color(hex: 0x4A8FE7)),
        ("normal", Color(hex: 0x30D158)),
        ("lite", Color(hex: 0xFF9F0A)),
        ("skip", Color(hex: 0x636366)),
    ]

    private var segments: [(name: String, count: Int, color: Color)] {
        [("premium", premium, tierColors[0].1),
         ("normal", normal, tierColors[1].1),
         ("lite", lite, tierColors[2].1),
         ("skip", skip, tierColors[3].1)]
    }

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                        if seg.count > 0 {
                            let width = geo.size.width * CGFloat(seg.count) / CGFloat(max(total, 1))
                            RoundedRectangle(cornerRadius: 3)
                                .fill(seg.color.opacity(0.7))
                                .frame(width: max(width, 4))
                        }
                    }
                }
            }
            .frame(height: 20)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            HStack(spacing: 16) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                    HStack(spacing: 4) {
                        Circle().fill(seg.color).frame(width: 8, height: 8)
                        Text("\(seg.name) \(seg.count)")
                            .font(.caption2)
                            .foregroundStyle(Color(hex: 0xA0A1A8))
                    }
                }
            }
        }
    }
}
```

- [ ] **Step 8: Build to verify**

```bash
cd /Users/example/-Code-/coding-memory/macos && xcodegen generate && xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build 2>&1 | tail -5
```

- [ ] **Step 9: Commit**

```bash
git add macos/Engram/Components/SourcePill.swift macos/Engram/Components/ProjectBadge.swift macos/Engram/Components/SessionCard.swift macos/Engram/Components/BarChart.swift macos/Engram/Components/ActivityChart.swift macos/Engram/Components/HeatmapGrid.swift macos/Engram/Components/TierBar.swift
git commit -m "feat(macos): add data display components — SourcePill, SessionCard, BarChart, ActivityChart, HeatmapGrid, TierBar"
```

---

### Task 6: Database Query Extensions

**Files:**
- Modify: `macos/Engram/Core/Database.swift`

Add these methods to `DatabaseManager`. All use the existing `pool.read` pattern from `listSessions()`.

- [ ] **Step 1: Add KPI stats method**

Add to DatabaseManager:

```swift
// MARK: - Dashboard Queries

struct KPIStats {
    let sessions: Int
    let sources: Int
    let messages: Int
    let projects: Int
}

func kpiStats() throws -> KPIStats {
    guard let pool else { throw DatabaseError.notOpen }
    return try pool.read { db in
        let row = try Row.fetchOne(db, sql: """
            SELECT
                COUNT(*) as sessions,
                COUNT(DISTINCT source) as sources,
                SUM(message_count) as messages,
                COUNT(DISTINCT project) as projects
            FROM sessions WHERE hidden_at IS NULL
        """)!
        return KPIStats(
            sessions: row["sessions"],
            sources: row["sources"],
            messages: row["messages"] ?? 0,
            projects: row["projects"]
        )
    }
}
```

- [ ] **Step 2: Add daily activity method**

```swift
func dailyActivity(days: Int = 30) throws -> [(date: String, count: Int)] {
    guard let pool else { throw DatabaseError.notOpen }
    return try pool.read { db in
        let rows = try Row.fetchAll(db, sql: """
            SELECT DATE(start_time) as day, COUNT(*) as count
            FROM sessions
            WHERE hidden_at IS NULL
              AND start_time >= DATE('now', '-\(days) days')
            GROUP BY day ORDER BY day
        """)
        return rows.map { (date: $0["day"] as String, count: $0["count"] as Int) }
    }
}
```

- [ ] **Step 3: Add hourly activity method**

```swift
func hourlyActivity() throws -> [Int] {
    guard let pool else { throw DatabaseError.notOpen }
    return try pool.read { db in
        let rows = try Row.fetchAll(db, sql: """
            SELECT CAST(strftime('%H', start_time, 'localtime') AS INTEGER) as hour,
                   COUNT(*) as count
            FROM sessions
            WHERE hidden_at IS NULL
            GROUP BY hour ORDER BY hour
        """)
        var hours = Array(repeating: 0, count: 24)
        for row in rows {
            let h: Int = row["hour"]
            let c: Int = row["count"]
            if h >= 0 && h < 24 { hours[h] = c }
        }
        return hours
    }
}
```

- [ ] **Step 4: Add source distribution method**

```swift
func sourceDistribution() throws -> [(source: String, count: Int)] {
    guard let pool else { throw DatabaseError.notOpen }
    return try pool.read { db in
        let rows = try Row.fetchAll(db, sql: """
            SELECT source, COUNT(*) as count
            FROM sessions WHERE hidden_at IS NULL
            GROUP BY source ORDER BY count DESC
        """)
        return rows.map { (source: $0["source"] as String, count: $0["count"] as Int) }
    }
}
```

- [ ] **Step 5: Add tier distribution method**

```swift
func tierDistribution() throws -> (premium: Int, normal: Int, lite: Int, skip: Int) {
    guard let pool else { throw DatabaseError.notOpen }
    return try pool.read { db in
        let rows = try Row.fetchAll(db, sql: """
            SELECT COALESCE(tier, 'normal') as t, COUNT(*) as count
            FROM sessions WHERE hidden_at IS NULL
            GROUP BY t
        """)
        var result = (premium: 0, normal: 0, lite: 0, skip: 0)
        for row in rows {
            let t: String = row["t"]
            let c: Int = row["count"]
            switch t {
            case "premium": result.premium = c
            case "normal":  result.normal = c
            case "lite":    result.lite = c
            case "skip":    result.skip = c
            default:        result.normal += c
            }
        }
        return result
    }
}
```

- [ ] **Step 6: Add recent sessions method**

```swift
func recentSessions(limit: Int = 8) throws -> [Session] {
    guard let pool else { throw DatabaseError.notOpen }
    return try pool.read { db in
        try Session.fetchAll(db, sql: """
            SELECT * FROM sessions
            WHERE hidden_at IS NULL AND (tier IS NULL OR tier != 'skip')
            ORDER BY start_time DESC LIMIT ?
        """, arguments: [limit])
    }
}
```

- [ ] **Step 7: Add session timeline method**

```swift
func sessionTimeline(days: Int = 30) throws -> [(date: String, sessions: [Session])] {
    guard let pool else { throw DatabaseError.notOpen }
    return try pool.read { db in
        let sessions = try Session.fetchAll(db, sql: """
            SELECT * FROM sessions
            WHERE hidden_at IS NULL
              AND start_time >= DATE('now', '-\(days) days')
              AND (tier IS NULL OR tier != 'skip')
            ORDER BY start_time DESC
        """)
        let grouped = Dictionary(grouping: sessions) { String($0.startTime.prefix(10)) }
        return grouped.sorted { $0.key > $1.key }
            .map { (date: $0.key, sessions: $0.value) }
    }
}
```

- [ ] **Step 8: Add list sessions by project method**

```swift
struct ProjectGroup: Identifiable {
    let id: String
    let project: String
    let sessionCount: Int
    let lastActive: String
    let sessions: [Session]
}

func listSessionsByProject(limit: Int = 100) throws -> [ProjectGroup] {
    guard let pool else { throw DatabaseError.notOpen }
    return try pool.read { db in
        let sessions = try Session.fetchAll(db, sql: """
            SELECT * FROM sessions
            WHERE hidden_at IS NULL AND project IS NOT NULL
              AND (tier IS NULL OR tier != 'skip')
            ORDER BY start_time DESC
            LIMIT ?
        """, arguments: [limit * 10])  // Fetch more rows to group
        let grouped = Dictionary(grouping: sessions) { $0.project ?? "(unknown)" }
        return grouped.map { project, sessions in
            ProjectGroup(
                id: project,
                project: project,
                sessionCount: sessions.count,
                lastActive: sessions.first?.startTime ?? "",
                sessions: Array(sessions.prefix(limit))
            )
        }
        .sorted { $0.lastActive > $1.lastActive }
    }
}
```

- [ ] **Step 9: Build to verify**

```bash
cd /Users/example/-Code-/coding-memory/macos && xcodegen generate && xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build 2>&1 | tail -5
```

- [ ] **Step 10: Commit**

```bash
git add macos/Engram/Core/Database.swift
git commit -m "feat(macos): add dashboard query methods to DatabaseManager"
```

---

### Task 7: Daemon API Endpoints (TypeScript)

**Files:**
- Modify: `src/web.ts`
- Test: `tests/web.test.ts` (if exists, else verify with curl)

These endpoints read from the filesystem, not from the DB. The `adapters` option is already passed to `createApp()`.

- [ ] **Step 1: Write tests for new endpoints**

Check if web.test.ts exists, and add tests:

```bash
ls tests/web*.ts 2>/dev/null || echo "No existing web tests"
```

If no test file exists, we'll verify with curl after `npm run dev`. If it does, add tests for the 4 new endpoints.

- [ ] **Step 2: Add /api/sources endpoint**

Add to `src/web.ts` after the existing `/api/health/sources` endpoint (around line 465):

```typescript
// Active sources with adapter info
app.get('/api/sources', async (c) => {
    const sources = db.listSources()
    const stats = db.getSourceStats()
    const statsMap = new Map(stats.map(s => [s.source, s]))
    return c.json(sources.map(source => ({
        name: source,
        sessionCount: statsMap.get(source)?.sessionCount ?? 0,
        latestIndexed: statsMap.get(source)?.latestIndexed ?? null,
    })))
})
```

- [ ] **Step 3: Add /api/skills endpoint**

```typescript
import { readdir, readFile, stat } from 'fs/promises'

// Skills from Claude Code config
app.get('/api/skills', async (c) => {
    const results: { name: string; description: string; path: string; scope: string }[] = []
    const home = homedir()

    // Global commands from settings
    try {
        const settingsPath = join(home, '.claude', 'settings.json')
        const raw = await readFile(settingsPath, 'utf-8')
        const settings = JSON.parse(raw)
        if (settings.customCommands) {
            for (const [name, cmd] of Object.entries(settings.customCommands)) {
                results.push({ name, description: String(cmd).slice(0, 100), path: settingsPath, scope: 'global' })
            }
        }
    } catch { /* no settings */ }

    // Plugin skills
    const pluginsDir = join(home, '.claude', 'plugins', 'cache')
    try {
        const vendors = await readdir(pluginsDir)
        for (const vendor of vendors) {
            const vendorPath = join(pluginsDir, vendor)
            const vendorStat = await stat(vendorPath).catch(() => null)
            if (!vendorStat?.isDirectory()) continue
            // Walk skill directories looking for skill.md files
            const items = await readdir(vendorPath, { recursive: true })
            for (const item of items) {
                if (typeof item === 'string' && item.endsWith('.md') && !item.includes('node_modules')) {
                    try {
                        const content = await readFile(join(vendorPath, item), 'utf-8')
                        const nameMatch = content.match(/^name:\s*(.+)$/m)
                        const descMatch = content.match(/^description:\s*(.+)$/m)
                        if (nameMatch) {
                            results.push({
                                name: nameMatch[1].trim(),
                                description: descMatch?.[1]?.trim() ?? '',
                                path: join(vendorPath, item).replace(home, '~'),
                                scope: 'plugin',
                            })
                        }
                    } catch { /* skip unreadable */ }
                }
            }
        }
    } catch { /* no plugins dir */ }

    return c.json(results)
})
```

- [ ] **Step 4: Add /api/memory endpoint**

```typescript
// Memory files across Claude Code projects
app.get('/api/memory', async (c) => {
    const results: { name: string; project: string; path: string; sizeBytes: number; preview: string }[] = []
    const home = homedir()
    const projectsDir = join(home, '.claude', 'projects')

    try {
        const projects = await readdir(projectsDir)
        for (const project of projects) {
            const memoryDir = join(projectsDir, project, 'memory')
            try {
                const files = await readdir(memoryDir)
                for (const file of files) {
                    if (!file.endsWith('.md')) continue
                    const filePath = join(memoryDir, file)
                    const fileStat = await stat(filePath).catch(() => null)
                    if (!fileStat?.isFile()) continue
                    const content = await readFile(filePath, 'utf-8').catch(() => '')
                    results.push({
                        name: file,
                        project: project.replace(/-/g, '/'),
                        path: filePath.replace(home, '~'),
                        sizeBytes: fileStat.size,
                        preview: content.slice(0, 200),
                    })
                }
            } catch { /* no memory dir for this project */ }
        }
    } catch { /* no projects dir */ }

    return c.json(results)
})
```

- [ ] **Step 5: Add /api/hooks endpoint**

```typescript
// Hooks from Claude Code settings
app.get('/api/hooks', async (c) => {
    const results: { event: string; command: string; scope: string }[] = []
    const home = homedir()

    for (const scope of ['global', 'project'] as const) {
        const path = scope === 'global'
            ? join(home, '.claude', 'settings.json')
            : join(home, '.claude', 'settings.local.json')
        try {
            const raw = await readFile(path, 'utf-8')
            const settings = JSON.parse(raw)
            if (settings.hooks) {
                for (const [event, handlers] of Object.entries(settings.hooks)) {
                    if (Array.isArray(handlers)) {
                        for (const handler of handlers) {
                            const cmd = typeof handler === 'string' ? handler
                                : (handler as { command?: string }).command ?? JSON.stringify(handler)
                            results.push({ event, command: cmd, scope })
                        }
                    }
                }
            }
        } catch { /* no settings file */ }
    }

    return c.json(results)
})
```

- [ ] **Step 6: Add missing import**

At the top of `src/web.ts`, add `readdir`, `readFile`, `stat` imports:

```typescript
import { existsSync } from 'fs'
import { readdir, readFile, stat } from 'fs/promises'
```

(Note: `existsSync` is already imported. Add `readdir`, `readFile`, `stat` from `fs/promises`.)

- [ ] **Step 7: Build and verify**

```bash
cd /Users/example/-Code-/coding-memory && npm run build
```
Expected: No errors.

- [ ] **Step 8: Smoke test with daemon**

```bash
cd /Users/example/-Code-/coding-memory && npm run dev &
sleep 2
curl -s http://127.0.0.1:3457/api/sources | head -c 200
curl -s http://127.0.0.1:3457/api/skills | head -c 200
curl -s http://127.0.0.1:3457/api/memory | head -c 200
curl -s http://127.0.0.1:3457/api/hooks | head -c 200
kill %1
```

- [ ] **Step 9: Commit**

```bash
git add src/web.ts
git commit -m "feat: add /api/sources, /api/skills, /api/memory, /api/hooks endpoints"
```

---

### Task 8: DaemonClient (Swift HTTP Client)

**Files:**
- Create: `macos/Engram/Core/DaemonClient.swift`
- Modify: `macos/Engram/App.swift` (create + inject)
- Modify: `macos/Engram/MenuBarController.swift` (store + inject)

- [ ] **Step 1: Create DaemonClient.swift**

```swift
// macos/Engram/Core/DaemonClient.swift
import Foundation

@MainActor
class DaemonClient: ObservableObject {
    private let baseURL: String

    init(port: Int = 3457) {
        self.baseURL = "http://127.0.0.1:\(port)"
    }

    func fetch<T: Decodable>(_ path: String) async throws -> T {
        let url = URL(string: "\(baseURL)\(path)")!
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw DaemonClientError.httpError(
                (response as? HTTPURLResponse)?.statusCode ?? 0
            )
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    enum DaemonClientError: Error, LocalizedError {
        case httpError(Int)
        var errorDescription: String? {
            switch self {
            case .httpError(let code): return "HTTP \(code)"
            }
        }
    }
}

// MARK: - API Response Types

struct SourceInfo: Decodable, Identifiable {
    var id: String { name }
    let name: String
    let sessionCount: Int
    let latestIndexed: String?
}

struct SkillInfo: Decodable, Identifiable {
    var id: String { "\(scope)/\(name)" }
    let name: String
    let description: String
    let path: String
    let scope: String
}

struct MemoryFile: Decodable, Identifiable {
    var id: String { path }
    let name: String
    let project: String
    let path: String
    let sizeBytes: Int
    let preview: String
}

struct HookInfo: Decodable, Identifiable {
    var id: String { "\(scope)/\(event)/\(command)" }
    let event: String
    let command: String
    let scope: String
}
```

- [ ] **Step 2: Modify App.swift to create and inject DaemonClient**

In `AppDelegate`, add the `daemonClient` property:

```swift
// In AppDelegate class, after existing properties:
let daemonClient = DaemonClient()
```

- [ ] **Step 3: Modify MenuBarController to accept and inject DaemonClient**

In `MenuBarController.swift`:

1. Add property:
```swift
private let daemonClient: DaemonClient
```

2. Update init:
```swift
init(db: DatabaseManager, indexer: IndexerProcess, daemonClient: DaemonClient) {
    self.db = db
    self.indexer = indexer
    self.daemonClient = daemonClient
    // ... rest unchanged
```

3. Update popover creation to inject daemonClient:
```swift
popover.contentViewController = NSHostingController(
    rootView: PopoverView()
        .environmentObject(db)
        .environmentObject(indexer)
        .environmentObject(daemonClient)
)
```

4. Update `openWindow()` (will be changed fully in Task 10, but for now keep it compiling):
```swift
let hostingController = NSHostingController(
    rootView: ContentView()
        .environmentObject(db)
        .environmentObject(indexer)
        .environmentObject(daemonClient)
)
```

- [ ] **Step 4: Update AppDelegate to pass daemonClient to MenuBarController**

```swift
menuBarController = MenuBarController(db: db, indexer: indexer, daemonClient: daemonClient)
```

Also inject into Settings scene:
```swift
var body: some Scene {
    Settings {
        SettingsView()
            .environmentObject(appDelegate.db)
            .environmentObject(appDelegate.indexer)
            .environmentObject(appDelegate.daemonClient)
    }
}
```

- [ ] **Step 5: Build to verify**

```bash
cd /Users/example/-Code-/coding-memory/macos && xcodegen generate && xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build 2>&1 | tail -5
```

- [ ] **Step 6: Commit**

```bash
git add macos/Engram/Core/DaemonClient.swift macos/Engram/App.swift macos/Engram/MenuBarController.swift
git commit -m "feat(macos): add DaemonClient HTTP client and wire into environment"
```

---

### Task 9: Navigation Shell — MainWindowView + SidebarView

**Files:**
- Create: `macos/Engram/Views/MainWindowView.swift`
- Create: `macos/Engram/Views/SidebarView.swift`

- [ ] **Step 1: Create SidebarView.swift**

```swift
// macos/Engram/Views/SidebarView.swift
import SwiftUI

struct SidebarView: View {
    @Binding var selectedScreen: Screen

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Screen.Section.allCases, id: \.self) { section in
                        Text(section.rawValue)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color(hex: 0x6E7078))
                            .padding(.horizontal, 12)
                            .padding(.top, section == .overview ? 8 : 16)
                            .padding(.bottom, 4)

                        ForEach(section.screens) { screen in
                            SidebarItem(
                                screen: screen,
                                isSelected: selectedScreen == screen,
                                action: { selectedScreen = screen }
                            )
                        }
                    }
                }
                .padding(.bottom, 8)
            }

            Divider()
                .opacity(0.2)

            // Pinned Settings button
            SidebarItem(
                screen: .settings,
                isSelected: selectedScreen == .settings,
                action: { selectedScreen = .settings }
            )
            .padding(.vertical, 8)
        }
        .frame(minWidth: 160, maxWidth: 160)
    }
}

private struct SidebarItem: View {
    let screen: Screen
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: screen.icon)
                    .font(.system(size: 13))
                    .frame(width: 20)
                Text(screen.title)
                    .font(.system(size: 13))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isSelected
                ? Color(hex: 0x4A8FE7).opacity(0.25)
                : Color.clear)
            .foregroundStyle(isSelected
                ? Color(hex: 0x6CB4FF)
                : Color(hex: 0xA0A1A8))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
    }
}
```

- [ ] **Step 2: Create MainWindowView.swift with stub pages**

```swift
// macos/Engram/Views/MainWindowView.swift
import SwiftUI

struct MainWindowView: View {
    @State private var selectedScreen: Screen = .home
    @State private var selectedSession: Session? = nil
    @EnvironmentObject var db: DatabaseManager
    @EnvironmentObject var indexer: IndexerProcess
    @EnvironmentObject var daemonClient: DaemonClient

    var body: some View {
        NavigationSplitView {
            SidebarView(selectedScreen: $selectedScreen)
        } detail: {
            if let session = selectedSession {
                // Session detail with back button
                VStack(spacing: 0) {
                    HStack {
                        Button(action: { selectedSession = nil }) {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.left")
                                Text("Back")
                            }
                            .font(.callout)
                            .foregroundStyle(Color(hex: 0x4A8FE7))
                        }
                        .buttonStyle(.plain)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    SessionDetailView(session: session)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(hex: 0x1A1D24))
            } else {
                detailView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(hex: 0x1A1D24))
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onReceive(NotificationCenter.default.publisher(for: .openSession)) { notification in
            if let box = notification.object as? SessionBox {
                selectedSession = box.session
            }
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch selectedScreen {
        case .home:
            HomeView()
        case .search:
            StubPageView(screen: .search)
        case .sessions:
            StubPageView(screen: .sessions)
        case .timeline:
            StubPageView(screen: .timeline)
        case .activity:
            StubPageView(screen: .activity)
        case .projects:
            StubPageView(screen: .projects)
        case .sourcePulse:
            StubPageView(screen: .sourcePulse)
        case .skills:
            StubPageView(screen: .skills)
        case .agents:
            StubPageView(screen: .agents)
        case .memory:
            StubPageView(screen: .memory)
        case .hooks:
            StubPageView(screen: .hooks)
        case .settings:
            SettingsView()
        }
    }
}

/// Placeholder for pages not yet implemented
struct StubPageView: View {
    let screen: Screen

    var body: some View {
        EmptyState(
            icon: screen.icon,
            title: screen.title,
            message: "Coming soon"
        )
    }
}
```

- [ ] **Step 3: Build to verify**

```bash
cd /Users/example/-Code-/coding-memory/macos && xcodegen generate && xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build 2>&1 | tail -5
```

- [ ] **Step 4: Commit**

```bash
git add macos/Engram/Views/MainWindowView.swift macos/Engram/Views/SidebarView.swift
git commit -m "feat(macos): add NavigationSplitView shell with sidebar and stub pages"
```

---

### Task 10: Home Dashboard

**Files:**
- Create: `macos/Engram/Views/Pages/HomeView.swift`

- [ ] **Step 1: Create Pages directory**

```bash
mkdir -p /Users/example/-Code-/coding-memory/macos/Engram/Views/Pages
```

- [ ] **Step 2: Create HomeView.swift**

```swift
// macos/Engram/Views/Pages/HomeView.swift
import SwiftUI

struct HomeView: View {
    @EnvironmentObject var db: DatabaseManager

    @State private var kpi: DatabaseManager.KPIStats?
    @State private var dailyActivity: [(date: String, count: Int)] = []
    @State private var hourlyActivity: [Int] = Array(repeating: 0, count: 24)
    @State private var sourceDist: [(source: String, count: Int)] = []
    @State private var tiers: (premium: Int, normal: Int, lite: Int, skip: Int) = (0, 0, 0, 0)
    @State private var recentSessions: [Session] = []
    @State private var isLoading = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                greetingSection
                kpiSection
                chartsSection
                distributionSection
                recentSessionsSection
            }
            .padding(24)
        }
        .task { await loadData() }
    }

    // MARK: - Greeting

    private var greetingSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(greeting)
                .font(.title2)
                .fontWeight(.bold)
                .foregroundStyle(.white)
            if let kpi {
                Text("\(kpi.sessions) sessions across \(kpi.sources) sources")
                    .font(.callout)
                    .foregroundStyle(Color(hex: 0xA0A1A8))
            }
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let name = NSFullUserName().components(separatedBy: " ").first ?? NSUserName()
        switch hour {
        case 5..<12:  return "Good morning, \(name)"
        case 12..<17: return "Good afternoon, \(name)"
        case 17..<22: return "Good evening, \(name)"
        default:      return "Good night, \(name)"
        }
    }

    // MARK: - KPI

    @ViewBuilder
    private var kpiSection: some View {
        if let kpi {
            HStack(spacing: 12) {
                KPICard(value: formatNumber(kpi.sessions), label: "Sessions")
                KPICard(value: "\(kpi.sources)", label: "Sources")
                KPICard(value: formatNumber(kpi.messages), label: "Messages")
                KPICard(value: "\(kpi.projects)", label: "Projects")
            }
        } else {
            HStack(spacing: 12) {
                ForEach(0..<4, id: \.self) { _ in SkeletonRow() }
            }
        }
    }

    // MARK: - Charts

    private var chartsSection: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading) {
                SectionHeader(icon: "chart.bar", title: "Activity", badge: "30d")
                ActivityChart(data: dailyActivity)
                    .frame(height: 140)
            }
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading) {
                SectionHeader(icon: "clock", title: "When You Work")
                HeatmapGrid(data: hourlyActivity)
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Distribution

    private var distributionSection: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading) {
                SectionHeader(icon: "chart.pie", title: "Sources")
                BarChart(items: sourceDist.prefix(7).map { item in
                    BarChartItem(
                        label: SourceColors.label(for: item.source),
                        value: item.count,
                        color: SourceColors.color(for: item.source)
                    )
                })
            }
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading) {
                SectionHeader(icon: "square.stack.3d.up", title: "Tiers")
                TierBar(
                    premium: tiers.premium,
                    normal: tiers.normal,
                    lite: tiers.lite,
                    skip: tiers.skip
                )
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Recent Sessions

    private var recentSessionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(icon: "clock.arrow.circlepath", title: "Recent Sessions")
            if recentSessions.isEmpty && !isLoading {
                EmptyState(
                    icon: "bubble.left.and.bubble.right",
                    title: "No sessions yet",
                    message: "Sessions will appear here after indexing"
                )
                .frame(height: 100)
            } else {
                ForEach(recentSessions) { session in
                    SessionCard(session: session) {
                        NotificationCenter.default.post(
                            name: .openSession,
                            object: SessionBox(session)
                        )
                    }
                }
            }
        }
    }

    // MARK: - Data Loading

    private func loadData() async {
        isLoading = true
        defer { isLoading = false }

        do {
            kpi = try db.kpiStats()
            dailyActivity = try db.dailyActivity(days: 30)
            hourlyActivity = try db.hourlyActivity()
            sourceDist = try db.sourceDistribution()
            tiers = try db.tierDistribution()
            recentSessions = try db.recentSessions(limit: 8)
        } catch {
            print("HomeView load error:", error)
        }
    }

    private func formatNumber(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }
}
```

- [ ] **Step 3: Build to verify**

```bash
cd /Users/example/-Code-/coding-memory/macos && xcodegen generate && xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build 2>&1 | tail -5
```

- [ ] **Step 4: Commit**

```bash
git add macos/Engram/Views/Pages/HomeView.swift
git commit -m "feat(macos): add Home dashboard with KPIs, charts, and recent sessions"
```

---

### Task 11: Wire MainWindowView into MenuBarController

**Files:**
- Modify: `macos/Engram/MenuBarController.swift:213-217`

- [ ] **Step 1: Replace ContentView with MainWindowView in openWindow()**

Change the `openWindow()` method's hosting controller creation (around line 213-217):

From:
```swift
let hostingController = NSHostingController(
    rootView: ContentView()
        .environmentObject(db)
        .environmentObject(indexer)
        .environmentObject(daemonClient)
)
```

To:
```swift
let hostingController = NSHostingController(
    rootView: MainWindowView()
        .environmentObject(db)
        .environmentObject(indexer)
        .environmentObject(daemonClient)
)
```

- [ ] **Step 2: Build to verify**

```bash
cd /Users/example/-Code-/coding-memory/macos && xcodegen generate && xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build 2>&1 | tail -5
```

- [ ] **Step 3: Visual smoke test**

Build and launch the app from DerivedData:

```bash
open "$(find ~/Library/Developer/Xcode/DerivedData/Engram-* -path '*/Debug/Engram.app' -maxdepth 4 2>/dev/null | head -1)"
```

Verify:
- Click menu bar icon → popover still works as before
- Click "Open Window" → new NavigationSplitView with sidebar
- Home page shows KPIs, charts, recent sessions
- Clicking other sidebar items shows stub pages
- Settings page shows existing SettingsView

- [ ] **Step 4: Commit**

```bash
git add macos/Engram/MenuBarController.swift
git commit -m "feat(macos): wire MainWindowView into MenuBarController.openWindow()"
```

---

## Phase 2 — Pages (Parallel)

Each task below is independent and can be executed by a parallel subagent. All tasks depend on Phase 1 being complete.

**Prerequisites for all Phase 2 tasks:**
- All Phase 1 tasks committed
- Components available in `macos/Engram/Components/`
- DB queries available on `DatabaseManager`
- `DaemonClient` available via `@EnvironmentObject`
- Replace the `StubPageView(screen: .xxx)` line in `MainWindowView.swift` with the real view

### Task 12: Sessions Page

**Files:**
- Create: `macos/Engram/Views/Pages/SessionsPageView.swift`
- Modify: `macos/Engram/Views/MainWindowView.swift` (replace stub)

- [ ] **Step 1: Create SessionsPageView.swift**

```swift
// macos/Engram/Views/Pages/SessionsPageView.swift
import SwiftUI

struct SessionsPageView: View {
    @EnvironmentObject var db: DatabaseManager

    @State private var sessions: [Session] = []
    @State private var totalCount = 0
    @State private var totalMessages = 0
    @State private var timeFilter = "All Time"
    @State private var sourceFilter: String? = nil
    @State private var availableSources: [String] = []
    @State private var isLoading = true

    private let timeOptions = ["Today", "This Week", "This Month", "All Time"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // KPI row
                HStack(spacing: 12) {
                    KPICard(value: "\(totalCount)", label: "Total Sessions")
                    KPICard(value: formatNumber(totalMessages), label: "Messages")
                    KPICard(value: avgDuration, label: "Avg Duration")
                }

                // Filters
                HStack(spacing: 12) {
                    FilterPills(options: timeOptions, selected: $timeFilter)
                    Spacer()
                    if !availableSources.isEmpty {
                        Picker("Source", selection: Binding(
                            get: { sourceFilter ?? "All" },
                            set: { sourceFilter = $0 == "All" ? nil : $0 }
                        )) {
                            Text("All Sources").tag("All")
                            ForEach(availableSources, id: \.self) { source in
                                Text(SourceColors.label(for: source)).tag(source)
                            }
                        }
                        .frame(width: 140)
                    }
                }

                // Session list
                if sessions.isEmpty && !isLoading {
                    EmptyState(icon: "bubble.left.and.bubble.right", title: "No sessions", message: "No sessions match your filters")
                } else {
                    LazyVStack(spacing: 4) {
                        ForEach(sessions) { session in
                            SessionCard(session: session) {
                                NotificationCenter.default.post(name: .openSession, object: SessionBox(session))
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
        .task { await loadData() }
        .onChange(of: timeFilter) { _ in Task { await loadData() } }
        .onChange(of: sourceFilter) { _ in Task { await loadData() } }
    }

    private func loadData() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let sources: Set<String> = sourceFilter.map { [$0] } ?? []
            let since = sinceDate(for: timeFilter)
            sessions = try db.listSessions(sources: sources, since: since, subAgent: false, limit: 200)
            totalCount = sessions.count
            totalMessages = sessions.reduce(0) { $0 + $1.messageCount }
            availableSources = Array(Set(sessions.map(\.source))).sorted()
        } catch {
            print("SessionsPage error:", error)
        }
    }

    private func sinceDate(for filter: String) -> String? {
        let cal = Calendar.current
        let now = Date()
        let formatter = ISO8601DateFormatter()
        switch filter {
        case "Today": return formatter.string(from: cal.startOfDay(for: now))
        case "This Week": return formatter.string(from: cal.date(byAdding: .day, value: -7, to: now) ?? now)
        case "This Month": return formatter.string(from: cal.date(byAdding: .month, value: -1, to: now) ?? now)
        default: return nil
        }
    }

    private var avgDuration: String {
        let sessionsWithEnd = sessions.filter { $0.endTime != nil }
        guard !sessionsWithEnd.isEmpty else { return "—" }
        let formatter = ISO8601DateFormatter()
        let totalSeconds = sessionsWithEnd.compactMap { s -> TimeInterval? in
            guard let start = formatter.date(from: s.startTime),
                  let end = s.endTime.flatMap({ formatter.date(from: $0) }) else { return nil }
            return end.timeIntervalSince(start)
        }.reduce(0, +)
        let avg = totalSeconds / Double(sessionsWithEnd.count)
        if avg < 60 { return "\(Int(avg))s" }
        if avg < 3600 { return "\(Int(avg / 60))m" }
        return String(format: "%.1fh", avg / 3600)
    }

    private func formatNumber(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }
}
```

- [ ] **Step 2: Update MainWindowView — replace sessions stub**

In `MainWindowView.swift`, change:
```swift
case .sessions:
    StubPageView(screen: .sessions)
```
to:
```swift
case .sessions:
    SessionsPageView()
```

- [ ] **Step 3: Build to verify**

```bash
cd /Users/example/-Code-/coding-memory/macos && xcodegen generate && xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build 2>&1 | tail -5
```

- [ ] **Step 4: Commit**

```bash
git add macos/Engram/Views/Pages/SessionsPageView.swift macos/Engram/Views/MainWindowView.swift
git commit -m "feat(macos): add Sessions page with filtering and KPIs"
```

---

### Task 13: Timeline Page

**Files:**
- Create: `macos/Engram/Views/Pages/TimelinePageView.swift`
- Modify: `macos/Engram/Views/MainWindowView.swift` (replace stub)

- [ ] **Step 1: Create TimelinePageView.swift**

```swift
// macos/Engram/Views/Pages/TimelinePageView.swift
import SwiftUI

struct TimelinePageView: View {
    @EnvironmentObject var db: DatabaseManager
    @State private var timeline: [(date: String, sessions: [Session])] = []
    @State private var isLoading = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(icon: "chart.bar.xaxis", title: "Timeline", badge: "30d")

                if timeline.isEmpty && !isLoading {
                    EmptyState(icon: "calendar", title: "No activity", message: "No sessions in the last 30 days")
                } else {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(timeline, id: \.date) { group in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(formatDateLabel(group.date))
                                        .font(.headline)
                                        .foregroundStyle(.white)
                                    Text("\(group.sessions.count) sessions")
                                        .font(.caption)
                                        .foregroundStyle(Color(hex: 0x6E7078))
                                    Spacer()
                                }
                                .padding(.top, 4)

                                ForEach(group.sessions) { session in
                                    SessionCard(session: session) {
                                        NotificationCenter.default.post(name: .openSession, object: SessionBox(session))
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
        .task { await loadData() }
    }

    private func loadData() async {
        isLoading = true
        defer { isLoading = false }
        do {
            timeline = try db.sessionTimeline(days: 30)
        } catch {
            print("TimelinePage error:", error)
        }
    }

    private func formatDateLabel(_ dateStr: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: dateStr) else { return dateStr }
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        formatter.dateFormat = "EEEE, MMM d"
        return formatter.string(from: date)
    }
}
```

- [ ] **Step 2: Update MainWindowView — replace timeline stub**

```swift
case .timeline:
    TimelinePageView()
```

- [ ] **Step 3: Build + commit**

```bash
cd /Users/example/-Code-/coding-memory/macos && xcodegen generate && xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build 2>&1 | tail -5
git add macos/Engram/Views/Pages/TimelinePageView.swift macos/Engram/Views/MainWindowView.swift
git commit -m "feat(macos): add Timeline page with date-grouped sessions"
```

---

### Task 14: Activity Page

**Files:**
- Create: `macos/Engram/Views/Pages/ActivityView.swift`
- Modify: `macos/Engram/Views/MainWindowView.swift` (replace stub)

- [ ] **Step 1: Create ActivityView.swift**

```swift
// macos/Engram/Views/Pages/ActivityView.swift
import SwiftUI

struct ActivityView: View {
    @EnvironmentObject var db: DatabaseManager

    @State private var dailyActivity: [(date: String, count: Int)] = []
    @State private var hourlyActivity: [Int] = Array(repeating: 0, count: 24)
    @State private var sourceDist: [(source: String, count: Int)] = []
    @State private var todayCount = 0
    @State private var weekCount = 0
    @State private var isLoading = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // KPI row
                HStack(spacing: 12) {
                    KPICard(value: "\(sourceDist.count)", label: "Active Sources")
                    KPICard(value: "\(todayCount)", label: "Sessions Today")
                    KPICard(value: "\(weekCount)", label: "This Week")
                }

                // Activity chart (larger)
                SectionHeader(icon: "chart.bar", title: "Daily Activity", badge: "30d")
                ActivityChart(data: dailyActivity)
                    .frame(height: 200)

                // Heatmap
                SectionHeader(icon: "clock", title: "When You Work")
                HeatmapGrid(data: hourlyActivity)

                // Per-source breakdown
                SectionHeader(icon: "chart.pie", title: "By Source")
                ForEach(sourceDist.prefix(10), id: \.source) { item in
                    HStack {
                        SourcePill(source: item.source)
                        Spacer()
                        Text("\(item.count) sessions")
                            .font(.caption)
                            .foregroundStyle(Color(hex: 0xA0A1A8))
                    }
                    .padding(.vertical, 4)
                }
            }
            .padding(24)
        }
        .task { await loadData() }
    }

    private func loadData() async {
        isLoading = true
        defer { isLoading = false }
        do {
            dailyActivity = try db.dailyActivity(days: 30)
            hourlyActivity = try db.hourlyActivity()
            sourceDist = try db.sourceDistribution()

            let today = ISO8601DateFormatter().string(from: Calendar.current.startOfDay(for: Date()))
            let weekAgo = ISO8601DateFormatter().string(from: Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date())
            todayCount = try db.listSessions(since: today, limit: 1000).count
            weekCount = try db.listSessions(since: weekAgo, limit: 10000).count
        } catch {
            print("ActivityView error:", error)
        }
    }
}
```

- [ ] **Step 2: Update MainWindowView — replace activity stub**

```swift
case .activity:
    ActivityView()
```

- [ ] **Step 3: Build + commit**

```bash
cd /Users/example/-Code-/coding-memory/macos && xcodegen generate && xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build 2>&1 | tail -5
git add macos/Engram/Views/Pages/ActivityView.swift macos/Engram/Views/MainWindowView.swift
git commit -m "feat(macos): add Activity page with daily chart, heatmap, and source breakdown"
```

---

### Task 15: Projects Page

**Files:**
- Create: `macos/Engram/Views/Pages/ProjectsView.swift`
- Modify: `macos/Engram/Views/MainWindowView.swift` (replace stub)

- [ ] **Step 1: Create ProjectsView.swift**

```swift
// macos/Engram/Views/Pages/ProjectsView.swift
import SwiftUI

struct ProjectsView: View {
    @EnvironmentObject var db: DatabaseManager

    @State private var projectGroups: [DatabaseManager.ProjectGroup] = []
    @State private var selectedProject: DatabaseManager.ProjectGroup? = nil
    @State private var isLoading = true

    private var activeCount: Int {
        let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        let formatter = ISO8601DateFormatter()
        return projectGroups.filter { group in
            guard let date = formatter.date(from: group.lastActive) else { return false }
            return date > weekAgo
        }.count
    }

    private var avgSessions: Int {
        guard !projectGroups.isEmpty else { return 0 }
        return projectGroups.reduce(0) { $0 + $1.sessionCount } / projectGroups.count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    KPICard(value: "\(projectGroups.count)", label: "Total Projects")
                    KPICard(value: "\(activeCount)", label: "Active (7d)")
                    KPICard(value: "\(avgSessions)", label: "Avg Sessions")
                }

                if let selected = selectedProject {
                    // Project detail view
                    HStack {
                        Button(action: { selectedProject = nil }) {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.left")
                                Text("All Projects")
                            }
                            .font(.callout)
                            .foregroundStyle(Color(hex: 0x4A8FE7))
                        }
                        .buttonStyle(.plain)
                        Spacer()
                    }

                    SectionHeader(icon: "folder", title: selected.project)

                    ForEach(selected.sessions) { session in
                        SessionCard(session: session) {
                            NotificationCenter.default.post(name: .openSession, object: SessionBox(session))
                        }
                    }
                } else {
                    // Project list
                    SectionHeader(icon: "folder", title: "Projects")

                    if projectGroups.isEmpty && !isLoading {
                        EmptyState(icon: "folder", title: "No projects", message: "Sessions without project associations won't appear here")
                    } else {
                        LazyVStack(spacing: 4) {
                            ForEach(projectGroups) { group in
                                Button(action: { selectedProject = group }) {
                                    HStack {
                                        Text(group.project.split(separator: "/").last.map(String.init) ?? group.project)
                                            .font(.callout)
                                            .foregroundStyle(.white)
                                        Text(group.project)
                                            .font(.caption)
                                            .foregroundStyle(Color(hex: 0x6E7078))
                                            .lineLimit(1)
                                        Spacer()
                                        Text("\(group.sessionCount)")
                                            .font(.caption)
                                            .foregroundStyle(Color(hex: 0xA0A1A8))
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 2)
                                            .background(Color.white.opacity(0.06))
                                            .clipShape(Capsule())
                                        Text(relativeTime(group.lastActive))
                                            .font(.caption)
                                            .foregroundStyle(Color(hex: 0x6E7078))
                                            .frame(width: 40, alignment: .trailing)
                                        Image(systemName: "chevron.right")
                                            .font(.caption2)
                                            .foregroundStyle(Color(hex: 0x6E7078).opacity(0.5))
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 10)
                                    .background(Color.white.opacity(0.02))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(Color.white.opacity(0.04), lineWidth: 1)
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
        .task { await loadData() }
    }

    private func loadData() async {
        isLoading = true
        defer { isLoading = false }
        do {
            projectGroups = try db.listSessionsByProject()
        } catch {
            print("ProjectsView error:", error)
        }
    }

    private func relativeTime(_ iso: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else { return "" }
        let seconds = Int(-date.timeIntervalSinceNow)
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86400)d"
    }
}
```

- [ ] **Step 2: Update MainWindowView — replace projects stub**

```swift
case .projects:
    ProjectsView()
```

- [ ] **Step 3: Build + commit**

```bash
cd /Users/example/-Code-/coding-memory/macos && xcodegen generate && xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build 2>&1 | tail -5
git add macos/Engram/Views/Pages/ProjectsView.swift macos/Engram/Views/MainWindowView.swift
git commit -m "feat(macos): add Projects page with drill-down to project sessions"
```

---

### Task 16: Agents Page

**Files:**
- Create: `macos/Engram/Views/Pages/AgentsView.swift`
- Modify: `macos/Engram/Views/MainWindowView.swift` (replace stub)

- [ ] **Step 1: Create AgentsView.swift**

```swift
// macos/Engram/Views/Pages/AgentsView.swift
import SwiftUI

struct AgentsView: View {
    @EnvironmentObject var db: DatabaseManager

    @State private var agentSessions: [Session] = []
    @State private var isLoading = true

    private var activeCount: Int {
        let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        let formatter = ISO8601DateFormatter()
        return Set(agentSessions.filter { s in
            formatter.date(from: s.startTime).map { $0 > weekAgo } ?? false
        }.compactMap(\.agentRole)).count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    KPICard(value: "\(agentSessions.count)", label: "Agent Sessions")
                    KPICard(value: "\(activeCount)", label: "Active (7d)")
                }

                SectionHeader(icon: "cpu", title: "Agent Sessions")

                if agentSessions.isEmpty && !isLoading {
                    EmptyState(
                        icon: "cpu",
                        title: "No agent sessions",
                        message: "Agent sessions (subagents, dispatched tasks) will appear here"
                    )
                } else {
                    LazyVStack(spacing: 4) {
                        ForEach(agentSessions) { session in
                            HStack(spacing: 8) {
                                SessionCard(session: session) {
                                    NotificationCenter.default.post(name: .openSession, object: SessionBox(session))
                                }
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
        .task { await loadData() }
    }

    private func loadData() async {
        isLoading = true
        defer { isLoading = false }
        do {
            agentSessions = try db.listSessions(subAgent: true, limit: 200)
        } catch {
            print("AgentsView error:", error)
        }
    }
}
```

- [ ] **Step 2: Update MainWindowView — replace agents stub**

```swift
case .agents:
    AgentsView()
```

- [ ] **Step 3: Build + commit**

```bash
cd /Users/example/-Code-/coding-memory/macos && xcodegen generate && xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build 2>&1 | tail -5
git add macos/Engram/Views/Pages/AgentsView.swift macos/Engram/Views/MainWindowView.swift
git commit -m "feat(macos): add Agents page showing subagent sessions"
```

---

### Task 17: Source Pulse Page

**Files:**
- Create: `macos/Engram/Views/Pages/SourcePulseView.swift`
- Modify: `macos/Engram/Views/MainWindowView.swift` (replace stub)

- [ ] **Step 1: Create SourcePulseView.swift**

```swift
// macos/Engram/Views/Pages/SourcePulseView.swift
import SwiftUI

struct SourcePulseView: View {
    @EnvironmentObject var db: DatabaseManager
    @EnvironmentObject var daemonClient: DaemonClient

    @State private var sources: [SourceInfo] = []
    @State private var sourceDist: [(source: String, count: Int)] = []
    @State private var isLoading = true
    @State private var error: String? = nil

    private var totalIndexed: Int { sources.reduce(0) { $0 + $1.sessionCount } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    KPICard(value: "\(sources.count)", label: "Active Sources")
                    KPICard(value: formatNumber(totalIndexed), label: "Total Indexed")
                }

                if let error {
                    AlertBanner(message: "Failed to load source data: \(error)")
                }

                SectionHeader(icon: "antenna.radiowaves.left.and.right", title: "Sources",
                             onRefresh: { Task { await loadData() } })

                if sources.isEmpty && !isLoading {
                    EmptyState(icon: "antenna.radiowaves.left.and.right", title: "No sources", message: "No adapter sources detected")
                } else {
                    LazyVStack(spacing: 4) {
                        ForEach(sources) { source in
                            HStack(spacing: 12) {
                                SourcePill(source: source.name)
                                Spacer()
                                Text("\(source.sessionCount) sessions")
                                    .font(.caption)
                                    .foregroundStyle(Color(hex: 0xA0A1A8))
                                if let latest = source.latestIndexed {
                                    Text(latest.prefix(10))
                                        .font(.caption)
                                        .foregroundStyle(Color(hex: 0x6E7078))
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(Color.white.opacity(0.02))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.white.opacity(0.04), lineWidth: 1)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }

                // Source distribution chart
                if !sourceDist.isEmpty {
                    SectionHeader(icon: "chart.pie", title: "Distribution")
                    BarChart(items: sourceDist.prefix(10).map { item in
                        BarChartItem(
                            label: SourceColors.label(for: item.source),
                            value: item.count,
                            color: SourceColors.color(for: item.source)
                        )
                    })
                }
            }
            .padding(24)
        }
        .task { await loadData() }
    }

    private func loadData() async {
        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            sources = try await daemonClient.fetch("/api/sources")
        } catch {
            self.error = error.localizedDescription
            // Fallback to DB
            do {
                sourceDist = try db.sourceDistribution()
                sources = sourceDist.map { SourceInfo(name: $0.source, sessionCount: $0.count, latestIndexed: nil) }
            } catch { /* ignore */ }
        }

        do {
            sourceDist = try db.sourceDistribution()
        } catch { /* ignore */ }
    }

    private func formatNumber(_ n: Int) -> String {
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }
}
```

- [ ] **Step 2: Update MainWindowView — replace sourcePulse stub**

```swift
case .sourcePulse:
    SourcePulseView()
```

- [ ] **Step 3: Build + commit**

```bash
cd /Users/example/-Code-/coding-memory/macos && xcodegen generate && xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build 2>&1 | tail -5
git add macos/Engram/Views/Pages/SourcePulseView.swift macos/Engram/Views/MainWindowView.swift
git commit -m "feat(macos): add Source Pulse page with adapter health and distribution"
```

---

### Task 18: Skills Page

**Files:**
- Create: `macos/Engram/Views/Pages/SkillsView.swift`
- Modify: `macos/Engram/Views/MainWindowView.swift` (replace stub)

- [ ] **Step 1: Create SkillsView.swift**

```swift
// macos/Engram/Views/Pages/SkillsView.swift
import SwiftUI

struct SkillsView: View {
    @EnvironmentObject var daemonClient: DaemonClient

    @State private var skills: [SkillInfo] = []
    @State private var searchText = ""
    @State private var isLoading = true
    @State private var error: String? = nil

    private var filteredSkills: [SkillInfo] {
        if searchText.isEmpty { return skills }
        let q = searchText.lowercased()
        return skills.filter { $0.name.lowercased().contains(q) || $0.description.lowercased().contains(q) }
    }

    private var globalSkills: [SkillInfo] { filteredSkills.filter { $0.scope == "global" } }
    private var pluginSkills: [SkillInfo] { filteredSkills.filter { $0.scope == "plugin" } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Search
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(Color(hex: 0x6E7078))
                    TextField("Search skills...", text: $searchText)
                        .textFieldStyle(.plain)
                }
                .padding(10)
                .background(Color.white.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                if let error {
                    AlertBanner(message: error)
                }

                if !globalSkills.isEmpty {
                    SectionHeader(icon: "globe", title: "Global Commands")
                    ForEach(globalSkills) { skill in
                        skillRow(skill)
                    }
                }

                if !pluginSkills.isEmpty {
                    SectionHeader(icon: "puzzlepiece", title: "Plugin Skills")
                    ForEach(pluginSkills) { skill in
                        skillRow(skill)
                    }
                }

                if filteredSkills.isEmpty && !isLoading {
                    EmptyState(icon: "sparkles", title: "No skills found", message: "Skills from ~/.claude/ will appear here")
                }
            }
            .padding(24)
        }
        .task { await loadData() }
    }

    private func skillRow(_ skill: SkillInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(skill.name)
                .font(.callout)
                .fontWeight(.medium)
                .foregroundStyle(.white)
            if !skill.description.isEmpty {
                Text(skill.description)
                    .font(.caption)
                    .foregroundStyle(Color(hex: 0xA0A1A8))
                    .lineLimit(2)
            }
            Text(skill.path)
                .font(.caption2)
                .foregroundStyle(Color(hex: 0x6E7078))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.white.opacity(0.02))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.04), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func loadData() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            skills = try await daemonClient.fetch("/api/skills")
        } catch {
            self.error = "Could not load skills: \(error.localizedDescription)"
        }
    }
}
```

- [ ] **Step 2: Update MainWindowView — replace skills stub**

```swift
case .skills:
    SkillsView()
```

- [ ] **Step 3: Build + commit**

```bash
cd /Users/example/-Code-/coding-memory/macos && xcodegen generate && xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build 2>&1 | tail -5
git add macos/Engram/Views/Pages/SkillsView.swift macos/Engram/Views/MainWindowView.swift
git commit -m "feat(macos): add Skills page browsing installed Claude Code skills"
```

---

### Task 19: Memory Page

**Files:**
- Create: `macos/Engram/Views/Pages/MemoryView.swift`
- Modify: `macos/Engram/Views/MainWindowView.swift` (replace stub)

- [ ] **Step 1: Create MemoryView.swift**

```swift
// macos/Engram/Views/Pages/MemoryView.swift
import SwiftUI

struct MemoryView: View {
    @EnvironmentObject var daemonClient: DaemonClient

    @State private var memoryFiles: [MemoryFile] = []
    @State private var searchText = ""
    @State private var selectedFile: MemoryFile? = nil
    @State private var fileContent: String? = nil
    @State private var isLoading = true
    @State private var error: String? = nil

    private var filteredFiles: [MemoryFile] {
        if searchText.isEmpty { return memoryFiles }
        let q = searchText.lowercased()
        return memoryFiles.filter {
            $0.name.lowercased().contains(q) || $0.project.lowercased().contains(q) || $0.preview.lowercased().contains(q)
        }
    }

    private var groupedByProject: [(project: String, files: [MemoryFile])] {
        let grouped = Dictionary(grouping: filteredFiles) { $0.project }
        return grouped.sorted { $0.key < $1.key }
            .map { (project: $0.key, files: $0.value) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Search
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(Color(hex: 0x6E7078))
                    TextField("Search memory files...", text: $searchText)
                        .textFieldStyle(.plain)
                }
                .padding(10)
                .background(Color.white.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                if let error {
                    AlertBanner(message: error)
                }

                if let selected = selectedFile {
                    // Detail view
                    HStack {
                        Button(action: { selectedFile = nil; fileContent = nil }) {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.left")
                                Text("All Memory")
                            }
                            .font(.callout)
                            .foregroundStyle(Color(hex: 0x4A8FE7))
                        }
                        .buttonStyle(.plain)
                        Spacer()
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text(selected.name)
                            .font(.headline)
                            .foregroundStyle(.white)
                        Text(selected.project)
                            .font(.caption)
                            .foregroundStyle(Color(hex: 0x6E7078))
                        Divider().opacity(0.2)
                        Text(fileContent ?? selected.preview)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(Color(hex: 0xA0A1A8))
                            .textSelection(.enabled)
                    }
                    .padding(16)
                    .background(Color.white.opacity(0.02))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    // List view
                    ForEach(groupedByProject, id: \.project) { group in
                        SectionHeader(icon: "folder", title: group.project)
                        ForEach(group.files) { file in
                            Button(action: { selectedFile = file }) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(file.name)
                                            .font(.callout)
                                            .foregroundStyle(.white)
                                        Text(file.preview.prefix(80))
                                            .font(.caption)
                                            .foregroundStyle(Color(hex: 0x6E7078))
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Text(formatSize(file.sizeBytes))
                                        .font(.caption)
                                        .foregroundStyle(Color(hex: 0x6E7078))
                                    Image(systemName: "chevron.right")
                                        .font(.caption2)
                                        .foregroundStyle(Color(hex: 0x6E7078).opacity(0.5))
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(Color.white.opacity(0.02))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.white.opacity(0.04), lineWidth: 1)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if filteredFiles.isEmpty && !isLoading {
                        EmptyState(icon: "brain", title: "No memory files", message: "Memory files from ~/.claude/projects/ will appear here")
                    }
                }
            }
            .padding(24)
        }
        .task { await loadData() }
    }

    private func loadData() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            memoryFiles = try await daemonClient.fetch("/api/memory")
        } catch {
            self.error = "Could not load memory: \(error.localizedDescription)"
        }
    }

    private func formatSize(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        return String(format: "%.0f KB", Double(bytes) / 1024)
    }
}
```

- [ ] **Step 2: Update MainWindowView — replace memory stub**

```swift
case .memory:
    MemoryView()
```

- [ ] **Step 3: Build + commit**

```bash
cd /Users/example/-Code-/coding-memory/macos && xcodegen generate && xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build 2>&1 | tail -5
git add macos/Engram/Views/Pages/MemoryView.swift macos/Engram/Views/MainWindowView.swift
git commit -m "feat(macos): add Memory page browsing Claude Code memory files"
```

---

### Task 20: Hooks Page

**Files:**
- Create: `macos/Engram/Views/Pages/HooksView.swift`
- Modify: `macos/Engram/Views/MainWindowView.swift` (replace stub)

- [ ] **Step 1: Create HooksView.swift**

```swift
// macos/Engram/Views/Pages/HooksView.swift
import SwiftUI

struct HooksView: View {
    @EnvironmentObject var daemonClient: DaemonClient

    @State private var hooks: [HookInfo] = []
    @State private var isLoading = true
    @State private var error: String? = nil

    private var globalHooks: [HookInfo] { hooks.filter { $0.scope == "global" } }
    private var projectHooks: [HookInfo] { hooks.filter { $0.scope == "project" } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let error {
                    AlertBanner(message: error)
                }

                if !globalHooks.isEmpty {
                    SectionHeader(icon: "globe", title: "Global Hooks")
                    ForEach(globalHooks) { hook in hookRow(hook) }
                }

                if !projectHooks.isEmpty {
                    SectionHeader(icon: "folder", title: "Project Hooks")
                    ForEach(projectHooks) { hook in hookRow(hook) }
                }

                if hooks.isEmpty && !isLoading {
                    EmptyState(
                        icon: "link",
                        title: "No hooks configured",
                        message: "Hooks from ~/.claude/settings.json will appear here"
                    )
                }
            }
            .padding(24)
        }
        .task { await loadData() }
    }

    private func hookRow(_ hook: HookInfo) -> some View {
        HStack(spacing: 12) {
            Text(hook.event)
                .font(.caption)
                .fontWeight(.medium)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(hex: 0x4A8FE7).opacity(0.15))
                .foregroundStyle(Color(hex: 0x4A8FE7))
                .clipShape(Capsule())
            Text(hook.command)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Color(hex: 0xA0A1A8))
                .lineLimit(2)
            Spacer()
        }
        .padding(12)
        .background(Color.white.opacity(0.02))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.04), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func loadData() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            hooks = try await daemonClient.fetch("/api/hooks")
        } catch {
            self.error = "Could not load hooks: \(error.localizedDescription)"
        }
    }
}
```

- [ ] **Step 2: Update MainWindowView — replace hooks stub**

```swift
case .hooks:
    HooksView()
```

- [ ] **Step 3: Build + commit**

```bash
cd /Users/example/-Code-/coding-memory/macos && xcodegen generate && xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build 2>&1 | tail -5
git add macos/Engram/Views/Pages/HooksView.swift macos/Engram/Views/MainWindowView.swift
git commit -m "feat(macos): add Hooks page showing configured Claude Code hooks"
```

---

### Task 21: Search Page

**Files:**
- Create: `macos/Engram/Views/Pages/SearchPageView.swift`
- Modify: `macos/Engram/Views/MainWindowView.swift` (replace stub)

This is a new page — the existing `SearchView.swift` in Popover is kept intact. The page version has a full-width layout with FilterPills.

- [ ] **Step 1: Create SearchPageView.swift**

```swift
// macos/Engram/Views/Pages/SearchPageView.swift
import SwiftUI

struct SearchPageView: View {
    @EnvironmentObject var db: DatabaseManager

    @State private var query = ""
    @State private var timeFilter = "All Time"
    @State private var results: [Session] = []
    @State private var isSearching = false

    private let timeOptions = ["Today", "This Week", "This Month", "All Time"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Search bar
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(Color(hex: 0x6E7078))
                    TextField("Search sessions...", text: $query)
                        .textFieldStyle(.plain)
                        .onSubmit { Task { await performSearch() } }
                    if !query.isEmpty {
                        Button(action: { query = ""; results = [] }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(Color(hex: 0x6E7078))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(12)
                .background(Color.white.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 10))

                // Filter pills
                FilterPills(options: timeOptions, selected: $timeFilter)

                // Results
                if results.isEmpty && !query.isEmpty && !isSearching {
                    EmptyState(icon: "magnifyingglass", title: "No results", message: "Try a different search term")
                } else if results.isEmpty && query.isEmpty {
                    EmptyState(icon: "magnifyingglass", title: "Search sessions", message: "Search by summary, project, or content")
                } else {
                    Text("\(results.count) results")
                        .font(.caption)
                        .foregroundStyle(Color(hex: 0x6E7078))
                    LazyVStack(spacing: 4) {
                        ForEach(results) { session in
                            SessionCard(session: session) {
                                NotificationCenter.default.post(name: .openSession, object: SessionBox(session))
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
        .onChange(of: query) { _ in
            Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                await performSearch()
            }
        }
        .onChange(of: timeFilter) { _ in Task { await performSearch() } }
    }

    private func performSearch() async {
        guard !query.isEmpty else { results = []; return }
        isSearching = true
        defer { isSearching = false }

        do {
            // db.search(query:) returns [Session] directly (FTS + join)
            let searchResults = try db.search(query: query, limit: 100)
            let since = sinceDate(for: timeFilter)
            if let since {
                results = searchResults.filter { $0.startTime >= since }
            } else {
                results = searchResults
            }
        } catch {
            print("SearchPage error:", error)
        }
    }

    private func sinceDate(for filter: String) -> String? {
        let cal = Calendar.current
        let now = Date()
        let formatter = ISO8601DateFormatter()
        switch filter {
        case "Today": return formatter.string(from: cal.startOfDay(for: now))
        case "This Week": return formatter.string(from: cal.date(byAdding: .day, value: -7, to: now) ?? now)
        case "This Month": return formatter.string(from: cal.date(byAdding: .month, value: -1, to: now) ?? now)
        default: return nil
        }
    }
}
```

- [ ] **Step 2: Update MainWindowView — replace search stub**

```swift
case .search:
    SearchPageView()
```

- [ ] **Step 3: Build + commit**

```bash
cd /Users/example/-Code-/coding-memory/macos && xcodegen generate && xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build 2>&1 | tail -5
git add macos/Engram/Views/Pages/SearchPageView.swift macos/Engram/Views/MainWindowView.swift
git commit -m "feat(macos): add full-page Search with time filtering"
```

---

### Task 22: Settings Page Embed

**Files:**
- Modify: `macos/Engram/Views/MainWindowView.swift`

The existing `SettingsView` is already referenced in `MainWindowView.swift`. Since `SettingsView` is already a full view, this task just verifies it works correctly embedded in the NavigationSplitView detail area.

- [ ] **Step 1: Verify SettingsView is properly referenced**

In `MainWindowView.swift`, the settings case should already be:
```swift
case .settings:
    SettingsView()
```

If `SettingsView` requires `@EnvironmentObject` for `db` or `indexer`, these are already injected at the `MainWindowView` level and propagate automatically.

- [ ] **Step 2: Build + verify**

```bash
cd /Users/example/-Code-/coding-memory/macos && xcodegen generate && xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build 2>&1 | tail -5
```

No commit needed — this was handled in Task 9.

---

## Phase 2 Execution Strategy

**Parallel Dispatch Groups:**

| Group | Tasks | Dependencies |
|-------|-------|-------------|
| **A (GRDB-only)** | 12 (Sessions), 13 (Timeline), 14 (Activity), 15 (Projects), 16 (Agents) | Phase 1 complete |
| **B (Daemon API)** | 17 (Source Pulse), 18 (Skills), 19 (Memory), 20 (Hooks) | Phase 1 Tasks 7-8 complete |
| **C (Migration)** | 21 (Search), 22 (Settings) | Phase 1 complete |

All tasks in Groups A, B, and C can run in parallel with each other. Each task modifies only its own page file + one line in `MainWindowView.swift`.

**Merge conflict mitigation:** Each task modifies a different `case` in `MainWindowView.swift`'s switch statement. The changes are on different lines and should auto-merge cleanly. If using worktrees, merge one at a time.

---

## Final Verification

After all tasks are complete:

- [ ] Full build: `cd macos && xcodegen generate && xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build`
- [ ] TypeScript build: `npm run build`
- [ ] TypeScript tests: `npm test`
- [ ] Launch app and verify all 12 pages render
- [ ] Verify popover still works (not modified)
- [ ] Verify Settings works in both standalone window and embedded page
