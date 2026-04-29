# PR1: Transcript Enhancement — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rewrite SessionDetailView from a bubble-based text viewer into an interactive transcript browser with color-coded message types, find-in-transcript, filter chips, and a compact toolbar inspired by AgentSessions.

**Architecture:** Replace the current header + bubble layout with a two-row toolbar (mode/actions + filter chips) above a color-bar message list. New `MessageTypeClassifier` classifies parsed messages into 6 types (user/assistant/tool/error/code/system). New `IndexedMessage` wrapper adds per-type index. Find bar uses `@State` search text with `AttributedString` range highlighting in message content.

**Tech Stack:** SwiftUI (macOS 14+), existing `MessageParser`, `ContentSegmentParser`, `SegmentedMessageView`

**Spec:** `docs/superpowers/specs/2026-03-19-eight-prs-learning-from-agent-sessions-design.md` (PR1 section)

---

## File Structure

### New Files
| File | Responsibility |
|------|---------------|
| `macos/Engram/Views/Transcript/TranscriptToolbar.swift` | Two-row toolbar: favorite, mode switch, ID, font, copy, find |
| `macos/Engram/Views/Transcript/TranscriptFindBar.swift` | Find bar overlay: search field, match count, prev/next, close |
| `macos/Engram/Views/Transcript/MessageTypeChip.swift` | Single filter chip: color dot, label, count, up/down nav, toggle |
| `macos/Engram/Views/Transcript/ColorBarMessageView.swift` | Color-bar message row: 3px left bar + type label + content |
| `macos/Engram/Models/MessageTypeClassifier.swift` | Classify ChatMessage → MessageType enum |
| `macos/Engram/Models/IndexedMessage.swift` | Wrapper: ChatMessage + messageType + typeIndex |

### Modified Files
| File | Changes |
|------|---------|
| `macos/Engram/Views/SessionDetailView.swift` | Rewrite body to use new toolbar + color bars. Keep `generateSummary()`. Remove old header/bubble views |
| `macos/Engram/Views/ContentSegmentViews.swift` | No changes (reused by ColorBarMessageView for assistant messages) |
| `macos/Engram/Core/MessageParser.swift` | No changes to ChatMessage struct (IndexedMessage wraps it) |

### Code Removed / Moved
| Code | Action |
|------|--------|
| `CleanMessageBubble` (in SessionDetailView.swift) | Removed — replaced by `ColorBarMessageView` |
| `SourceDisplay` (in SessionDetailView.swift) | **Moved to `SourceColors.swift`** — used by SessionListView, TimelineView, PopoverView |
| `RawMessageRow` (in SessionDetailView.swift) | Kept inline (simple, used only in Text/JSON modes) |

---

## Task 1: MessageType and IndexedMessage Models

**Files:**
- Create: `macos/Engram/Models/MessageTypeClassifier.swift`
- Create: `macos/Engram/Models/IndexedMessage.swift`

- [ ] **Step 1: Create MessageTypeClassifier**

```swift
// macos/Engram/Models/MessageTypeClassifier.swift
import Foundation

enum MessageType: String, CaseIterable {
    case user
    case assistant
    case tool
    case error
    case code
    case system

    var label: String {
        switch self {
        case .user: return "User"
        case .assistant: return "Assistant"
        case .tool: return "Tools"
        case .error: return "Error"
        case .code: return "Code"
        case .system: return "System"
        }
    }

    var color: Color {
        switch self {
        case .user:      return Color(red: 0.23, green: 0.51, blue: 0.96)  // #3b82f6
        case .assistant: return Color(red: 0.55, green: 0.36, blue: 0.96)  // #8b5cf6
        case .tool:      return Color(red: 0.06, green: 0.73, blue: 0.51)  // #10b981
        case .error:     return Color(red: 0.94, green: 0.27, blue: 0.27)  // #ef4444
        case .code:      return Color(red: 0.39, green: 0.40, blue: 0.95)  // #6366f1
        case .system:    return Color.secondary                              // gray
        }
    }

    /// Types shown in the chip bar (system is hidden from chips, controlled by Settings toggle)
    static var chipTypes: [MessageType] { [.user, .assistant, .tool, .error, .code] }
}

struct MessageTypeClassifier {

    private static let toolPatterns: [String] = [
        "Tool:", "tool_call", "tool_result",
        "Read(", "Write(", "Edit(", "Bash(",
        "Grep(", "Glob(", "Agent(",
        "› tool:", "⟪out⟫"
    ]

    private static let errorPatterns: [String] = [
        "Error:", "error:", "ERROR",
        "failed", "Failed", "FAILED",
        "permission denied", "Permission denied",
        "not found", "Not found",
        "Exit code: 1", "exit code 1",
        "Command failed", "command failed"
    ]

    static func classify(_ message: ChatMessage) -> MessageType {
        // System prompts (CLAUDE.md, environment_context, etc.) → system
        if message.systemCategory == .systemPrompt {
            return .system
        }

        // Agent communication (tool calls, skills) → tool
        if message.systemCategory == .agentComm {
            return .tool
        }

        // User messages
        if message.role == "user" {
            return .user
        }

        // Check for error patterns (before tool, as errors in tool output)
        let content = message.content
        if containsErrorPattern(content) {
            return .error
        }

        // Check for tool patterns
        if containsToolPattern(content) {
            return .tool
        }

        // Check for code blocks (assistant messages with significant code)
        if message.role == "assistant" && hasSignificantCodeBlock(content) {
            return .code
        }

        // Default: assistant
        if message.role == "assistant" {
            return .assistant
        }

        // System prompts without agentComm classification
        return .assistant
    }

    private static func containsToolPattern(_ text: String) -> Bool {
        let prefix = text.prefix(500)
        return toolPatterns.contains { prefix.contains($0) }
    }

    private static func containsErrorPattern(_ text: String) -> Bool {
        let prefix = text.prefix(1000)
        return errorPatterns.contains { prefix.contains($0) }
    }

    private static func hasSignificantCodeBlock(_ text: String) -> Bool {
        // Code block must be >50% of content and have ``` markers
        guard text.contains("```") else { return false }
        let codeLen = text.components(separatedBy: "```")
            .enumerated()
            .filter { $0.offset % 2 == 1 }  // odd indices = inside code fences
            .map(\.element.count)
            .reduce(0, +)
        return codeLen > text.count / 2
    }
}
```

- [ ] **Step 2: Create IndexedMessage**

```swift
// macos/Engram/Models/IndexedMessage.swift
import Foundation

struct IndexedMessage: Identifiable {
    let id: UUID
    let message: ChatMessage
    let messageType: MessageType
    let typeIndex: Int  // 1-based: "User #3" means typeIndex=3

    init(message: ChatMessage, messageType: MessageType, typeIndex: Int) {
        self.id = message.id
        self.message = message
        self.messageType = messageType
        self.typeIndex = typeIndex
    }

    /// Build indexed messages from raw ChatMessages.
    /// Returns (indexedMessages, typeCounts).
    static func build(from messages: [ChatMessage]) -> (messages: [IndexedMessage], counts: [MessageType: Int]) {
        var counters: [MessageType: Int] = [:]
        for type in MessageType.allCases { counters[type] = 0 }

        let indexed = messages.map { msg in
            let type = MessageTypeClassifier.classify(msg)
            counters[type, default: 0] += 1
            return IndexedMessage(message: msg, messageType: type, typeIndex: counters[type]!)
        }
        return (indexed, counters)
    }
}
```

- [ ] **Step 3: Run xcodegen and build to verify compilation**

Run: `cd /Users/example/-Code-/coding-memory/macos && xcodegen generate && xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add macos/Engram/Models/MessageTypeClassifier.swift macos/Engram/Models/IndexedMessage.swift
git commit -m "feat(transcript): add MessageTypeClassifier and IndexedMessage models"
```

---

## Task 2: ColorBarMessageView

**Files:**
- Create: `macos/Engram/Views/Transcript/ColorBarMessageView.swift`

- [ ] **Step 1: Create ColorBarMessageView**

```swift
// macos/Engram/Views/Transcript/ColorBarMessageView.swift
import SwiftUI

struct ColorBarMessageView: View {
    let indexed: IndexedMessage
    let searchText: String  // highlight matches (empty = no highlight)
    @AppStorage("contentFontSize") var fontSize: Double = 14

    private var barColor: Color { indexed.messageType.color }

    private var typeLabel: String {
        "\(indexed.messageType.label.uppercased()) #\(indexed.typeIndex)"
    }

    /// Build an AttributedString with yellow highlight on search matches
    private func highlightedText(_ text: String) -> AttributedString {
        var attr = AttributedString(text)
        guard !searchText.isEmpty else { return attr }
        let lower = text.lowercased()
        let query = searchText.lowercased()
        var searchStart = lower.startIndex
        while let range = lower.range(of: query, range: searchStart..<lower.endIndex) {
            // Convert String range to AttributedString range
            if let attrRange = Range(NSRange(range, in: text), in: attr) {
                attr[attrRange].backgroundColor = .yellow
                attr[attrRange].foregroundColor = .black
            }
            searchStart = range.upperBound
        }
        return attr
    }

    var body: some View {
        HStack(spacing: 0) {
            // 3px color bar
            Rectangle()
                .fill(barColor)
                .frame(width: 3)

            // Content
            VStack(alignment: .leading, spacing: 4) {
                // Type label
                Text(typeLabel)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(barColor)

                // Message content (with search highlighting)
                switch indexed.messageType {
                case .assistant, .code:
                    if searchText.isEmpty {
                        SegmentedMessageView(content: indexed.message.content)
                    } else {
                        // When searching, render as highlighted plain text
                        Text(highlightedText(indexed.message.content))
                            .font(.system(size: fontSize))
                            .textSelection(.enabled)
                    }
                case .system:
                    // Collapsible system message (default collapsed)
                    CollapsibleSystemBubble(message: indexed.message)
                default:
                    Text(highlightedText(indexed.message.content))
                        .font(.system(size: fontSize))
                        .textSelection(.enabled)
                        .foregroundStyle(indexed.messageType == .error ? barColor.opacity(0.85) : .primary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .background(barColor.opacity(0.06))
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: 0, bottomLeadingRadius: 0,
                bottomTrailingRadius: 6, topTrailingRadius: 6
            )
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
        .contextMenu {
            Button("Copy Message") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(indexed.message.content, forType: .string)
            }
        }
    }
}
```

- [ ] **Step 2: Regenerate project and build**

Run: `cd /Users/example/-Code-/coding-memory/macos && xcodegen generate && xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED (xcodegen needed for new Views/Transcript/ directory)

- [ ] **Step 3: Commit**

```bash
git add macos/Engram/Views/Transcript/ColorBarMessageView.swift
git commit -m "feat(transcript): add ColorBarMessageView with color-coded left bar"
```

---

## Task 3: MessageTypeChip

**Files:**
- Create: `macos/Engram/Views/Transcript/MessageTypeChip.swift`

- [ ] **Step 1: Create MessageTypeChip**

```swift
// macos/Engram/Views/Transcript/MessageTypeChip.swift
import SwiftUI

struct MessageTypeChip: View {
    let type: MessageType
    let currentIndex: Int  // 0-based navigation position, -1 if not navigated
    let totalCount: Int
    let isVisible: Bool    // false = this type is filtered out
    let onToggle: () -> Void
    let onPrev: () -> Void
    let onNext: () -> Void

    private var chipColor: Color { type.color }

    var body: some View {
        HStack(spacing: 4) {
            // Toggle area (color dot + label) — separate button to avoid gesture conflict with nav arrows
            Button(action: onToggle) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(isVisible ? chipColor : .secondary)
                        .frame(width: 6, height: 6)
                    Text("\(type.label) \(currentIndex >= 0 ? "\(currentIndex + 1)/" : "")\(totalCount)")
                        .font(.system(size: 11))
                        .foregroundStyle(isVisible ? .primary : .secondary)
                }
            }
            .buttonStyle(.plain)

            if totalCount > 0 && isVisible {
                Button(action: onPrev) {
                    Text("∧").font(.system(size: 9))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Button(action: onNext) {
                    Text("∨").font(.system(size: 9))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .opacity(isVisible ? 1.0 : 0.5)
    }
}
```

- [ ] **Step 2: Build to verify**

Run: `cd /Users/example/-Code-/coding-memory/macos && xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build 2>&1 | tail -5`

- [ ] **Step 3: Commit**

```bash
git add macos/Engram/Views/Transcript/MessageTypeChip.swift
git commit -m "feat(transcript): add MessageTypeChip with count, nav, and toggle"
```

---

## Task 4: TranscriptFindBar

**Files:**
- Create: `macos/Engram/Views/Transcript/TranscriptFindBar.swift`

- [ ] **Step 1: Create TranscriptFindBar**

```swift
// macos/Engram/Views/Transcript/TranscriptFindBar.swift
import SwiftUI

struct TranscriptFindBar: View {
    @Binding var searchText: String
    @Binding var isVisible: Bool
    let matchCount: Int
    let currentMatch: Int  // 0-based, -1 if no matches
    let onPrev: () -> Void
    let onNext: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            // Search field
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
                TextField("Find in transcript...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($isFocused)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .frame(maxWidth: 220)

            // Match counter
            if !searchText.isEmpty {
                Text(matchCount > 0 ? "\(currentMatch + 1)/\(matchCount)" : "No matches")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                // Prev / Next
                Button(action: onPrev) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .disabled(matchCount == 0)

                Button(action: onNext) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .disabled(matchCount == 0)
            }

            Spacer()

            // Close
            Button {
                searchText = ""
                isVisible = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
        .onAppear { isFocused = true }
    }
}
```

- [ ] **Step 2: Build to verify**

Run: `cd /Users/example/-Code-/coding-memory/macos && xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build 2>&1 | tail -5`

- [ ] **Step 3: Commit**

```bash
git add macos/Engram/Views/Transcript/TranscriptFindBar.swift
git commit -m "feat(transcript): add TranscriptFindBar with match counter and navigation"
```

---

## Task 5: TranscriptToolbar

**Files:**
- Create: `macos/Engram/Views/Transcript/TranscriptToolbar.swift`

- [ ] **Step 1: Create TranscriptToolbar**

This is the compact two-row toolbar inspired by AgentSessions:
- Row 1: ★ | Session/Text/JSON | ID | A−/A+ | Copy | Find ⌘F
- Row 2: All | chips...

```swift
// macos/Engram/Views/Transcript/TranscriptToolbar.swift
import SwiftUI

enum TranscriptViewMode: String, CaseIterable {
    case session, text, json
    var label: String { rawValue.capitalized }
}

struct TranscriptToolbar: View {
    let session: Session
    let isFavorite: Bool
    let typeCounts: [MessageType: Int]
    let typeVisibility: [MessageType: Bool]
    let navPositions: [MessageType: Int]  // current nav index per type, -1 = not navigated

    let onToggleFavorite: () -> Void
    let onCopyAll: () -> Void
    let onToggleFind: () -> Void
    let onToggleType: (MessageType) -> Void
    let onShowAll: () -> Void
    let onNavPrev: (MessageType) -> Void
    let onNavNext: (MessageType) -> Void

    @Binding var viewMode: TranscriptViewMode
    @AppStorage("contentFontSize") var fontSize: Double = 14

    var body: some View {
        VStack(spacing: 0) {
            // Row 1: Actions
            HStack(spacing: 8) {
                // Favorite
                Button(action: onToggleFavorite) {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                        .foregroundStyle(isFavorite ? .yellow : .secondary)
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)

                Divider().frame(height: 14)

                // Mode segmented control
                Picker("", selection: $viewMode) {
                    ForEach(TranscriptViewMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)

                // Session ID
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(session.id, forType: .string)
                } label: {
                    Text("ID \(String(session.id.suffix(4)))")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Copy session ID: \(session.id)")

                Spacer()

                // Font size
                Button { fontSize = max(10, fontSize - 1) } label: {
                    Text("A−").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                Button { fontSize = min(22, fontSize + 1) } label: {
                    Text("A+").font(.system(size: 14)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                Divider().frame(height: 14)

                // Copy
                Button(action: onCopyAll) {
                    Text("Copy")
                        .font(.system(size: 11))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)

                Divider().frame(height: 14)

                // Find
                Button(action: onToggleFind) {
                    Text("Find ⌘F")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()

            // Row 2: Filter chips (only in session mode)
            if viewMode == .session {
                HStack(spacing: 10) {
                    // All button
                    Button(action: onShowAll) {
                        Text("All")
                            .font(.system(size: 11))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)

                    ForEach(MessageType.chipTypes, id: \.self) { type in
                        MessageTypeChip(
                            type: type,
                            currentIndex: navPositions[type] ?? -1,
                            totalCount: typeCounts[type] ?? 0,
                            isVisible: typeVisibility[type] ?? true,
                            onToggle: { onToggleType(type) },
                            onPrev: { onNavPrev(type) },
                            onNext: { onNavNext(type) }
                        )
                    }

                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)

                Divider()
            }
        }
        .background(.bar)
    }
}
```

- [ ] **Step 2: Build to verify**

Run: `cd /Users/example/-Code-/coding-memory/macos && xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build 2>&1 | tail -5`

- [ ] **Step 3: Commit**

```bash
git add macos/Engram/Views/Transcript/TranscriptToolbar.swift
git commit -m "feat(transcript): add TranscriptToolbar with two-row compact layout"
```

---

## Task 6: Rewrite SessionDetailView

**Files:**
- Modify: `macos/Engram/Views/SessionDetailView.swift`

This is the main integration task — wire everything together.

- [ ] **Step 1: Rewrite SessionDetailView body and state**

Replace the entire `SessionDetailView` struct body with the new toolbar + color-bar layout. Key changes:
- Remove `headerView` (replaced by TranscriptToolbar)
- Remove `CleanMessageBubble` (replaced by ColorBarMessageView)
- Add states: `viewMode`, `showFind`, `searchText`, `indexedMessages`, `typeCounts`, `typeVisibility`, `navPositions`
- Add keyboard shortcuts: ⌘F, ⌘+, ⌘-, ⌥⌘C, Escape
- Keep `RawMessageRow` for raw/json modes
- Keep `generateSummary()` method
- Filter logic: `displayIndexed` filters by `typeVisibility` and `showSystemPrompts`/`showAgentComm`

The rewrite replaces the existing `body`, `headerView`, and filter logic. `CleanMessageBubble` is removed (replaced by `ColorBarMessageView`). `RawMessageRow` stays in the file for Text/JSON modes.

**Preservation checklist** — these features from the current file MUST be kept:
- `.task(id: session.id)` for message loading (async parse off main thread)
- `isFavorite` state + `.task { db.isFavorite() }` on appear
- `generateSummary()` method + `isSummarizing` / `summaryError` / `currentSummary` states
- Size warning banner (for large/huge sessions)
- Loading spinner (`isLoadingMessages`)
- Empty state views (`ContentUnavailableView`)
- `showSystemPrompts` and `showAgentComm` @AppStorage toggles (now filter `.system` type)
- `SourceDisplay` enum — **move to SourceColors.swift**, do NOT delete (used by other views)

**Text/JSON mode rendering:**
- `.text` mode: reuse `RawMessageRow` with role prefixes (same as current `showRaw`)
- `.json` mode: render each message as pretty-printed JSON (raw JSONL line if available, else serialize ChatMessage)

Key state additions:
```swift
@State private var viewMode: TranscriptViewMode = .session
@State private var showFind = false
@State private var searchText = ""
@State private var currentMatchIndex = -1
@State private var indexedMessages: [IndexedMessage] = []
@State private var typeCounts: [MessageType: Int] = [:]
@State private var typeVisibility: [MessageType: Bool] = MessageType.allCases.reduce(into: [:]) { $0[$1] = true }
@State private var navPositions: [MessageType: Int] = MessageType.allCases.reduce(into: [:]) { $0[$1] = -1 }
```

Key computed properties:
```swift
var displayIndexed: [IndexedMessage] {
    indexedMessages.filter { idx in
        guard typeVisibility[idx.messageType] ?? true else { return false }
        if !showSystemPrompts && idx.message.systemCategory == .systemPrompt { return false }
        if !showAgentComm && idx.message.systemCategory == .agentComm { return false }
        return true
    }
}

var matchIndices: [Int] {
    guard !searchText.isEmpty else { return [] }
    let query = searchText.lowercased()
    return displayIndexed.enumerated().compactMap { i, msg in
        msg.message.content.lowercased().contains(query) ? i : nil
    }
}
```

- [ ] **Step 2: Add keyboard shortcuts**

Attach to the outermost view:
```swift
.keyboardShortcut("f", modifiers: .command)  // ⌘F → toggle find
// Font shortcuts via .onKeyPress or Button with keyboardShortcut
```

- [ ] **Step 3: Build and test manually**

Run: `cd /Users/example/-Code-/coding-memory/macos && xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

Then launch from DerivedData and verify:
1. Toolbar row 1 shows: ★ | Session/Text/JSON | ID xxxx | A−/A+ | Copy | Find ⌘F
2. Toolbar row 2 shows chips with counts
3. Messages display with color bars
4. ⌘F opens find bar
5. Typing in find bar shows match count
6. Clicking chips toggles visibility
7. Text/JSON modes still work

- [ ] **Step 4: Commit**

```bash
git add macos/Engram/Views/SessionDetailView.swift
git commit -m "feat(transcript): rewrite SessionDetailView with toolbar, color bars, and find"
```

---

## Task 7: Move SourceDisplay and Remove CleanMessageBubble

**Files:**
- Modify: `macos/Engram/Views/SessionDetailView.swift` (remove both)
- Modify: `macos/Engram/Components/SourceColors.swift` (add SourceDisplay)

- [ ] **Step 1: Move SourceDisplay to SourceColors.swift**

`SourceDisplay` is used by `SessionListView`, `TimelineView`, `PopoverView`. It must NOT be deleted. Move it from `SessionDetailView.swift` to `SourceColors.swift` where it logically belongs.

Check references first: `grep -rn "SourceDisplay" macos/Engram/`
Expected: SessionListView.swift, TimelineView.swift, PopoverView.swift, SourceColors.swift (after move)

- [ ] **Step 2: Remove CleanMessageBubble from SessionDetailView.swift**

`CleanMessageBubble` is only referenced within `SessionDetailView.swift` (now replaced by `ColorBarMessageView`). Safe to remove.

- [ ] **Step 3: Verify build**

Run: `cd /Users/example/-Code-/coding-memory/macos && xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED (SourceDisplay still accessible from new location)

- [ ] **Step 4: Commit**

```bash
git add macos/Engram/Views/SessionDetailView.swift macos/Engram/Components/SourceColors.swift
git commit -m "refactor(transcript): move SourceDisplay to SourceColors, remove CleanMessageBubble"
```

---

## Task 8: Wire Find Navigation with ScrollViewReader

**Files:**
- Modify: `macos/Engram/Views/SessionDetailView.swift`

- [ ] **Step 1: Add ScrollViewReader for find navigation**

Wrap the ScrollView in a `ScrollViewReader` and add `.id()` to each `ColorBarMessageView`. When `currentMatchIndex` changes, scroll to the matched message:

```swift
ScrollViewReader { proxy in
    ScrollView {
        // ... message list with .id(indexed.id) on each row
    }
    .onChange(of: currentMatchIndex) { _, newIndex in
        if newIndex >= 0 && newIndex < matchIndices.count {
            let targetIdx = matchIndices[newIndex]
            if targetIdx < displayIndexed.count {
                withAnimation {
                    proxy.scrollTo(displayIndexed[targetIdx].id, anchor: .center)
                }
            }
        }
    }
}
```

- [ ] **Step 2: Add ⌘G / ⇧⌘G for next/prev match**

Add keyboard shortcuts for match navigation.

- [ ] **Step 3: Test find flow end-to-end**

1. Open a session with multiple messages
2. Press ⌘F → find bar appears
3. Type a keyword → match count updates
4. Press ⌘G → scrolls to next match
5. Press ⇧⌘G → scrolls to previous match
6. Press Escape → find bar closes

- [ ] **Step 4: Commit**

```bash
git add macos/Engram/Views/SessionDetailView.swift
git commit -m "feat(transcript): wire find navigation with ScrollViewReader"
```

---

## Task 9: Wire Chip Navigation

**Files:**
- Modify: `macos/Engram/Views/SessionDetailView.swift`

- [ ] **Step 1: Implement chip ∧∨ navigation**

When user clicks ∧ (prev) or ∨ (next) on a chip, find the previous/next message of that type in `displayIndexed` and scroll to it:

```swift
func navigateType(_ type: MessageType, direction: Int) {
    let current = navPositions[type] ?? -1
    let matching = displayIndexed.enumerated().filter { $0.element.messageType == type }
    guard !matching.isEmpty else { return }

    let newPos: Int
    if direction > 0 {
        newPos = (current + 1) % matching.count
    } else {
        newPos = current <= 0 ? matching.count - 1 : current - 1
    }
    navPositions[type] = newPos

    // Scroll
    let target = matching[newPos]
    scrollProxy?.scrollTo(target.element.id, anchor: .center)
}
```

Use a `@State private var scrollTarget: UUID?` that triggers `.onChange` inside the `ScrollViewReader` closure. Do NOT store `ScrollViewProxy` in `@State` (it's only valid inside the reader closure). Set `scrollTarget = targetId` and let `.onChange(of: scrollTarget)` call `proxy.scrollTo()`.

- [ ] **Step 2: Test chip navigation**

1. Click ∨ on "User" chip → scrolls to User #1
2. Click ∨ again → scrolls to User #2
3. Click ∧ → scrolls back to User #1
4. Chip updates to show "1/6" → "2/6" etc.

- [ ] **Step 3: Commit**

```bash
git add macos/Engram/Views/SessionDetailView.swift
git commit -m "feat(transcript): wire chip navigation with scroll-to-type"
```

---

## Task 10: Copy All and Keyboard Shortcuts

**Files:**
- Modify: `macos/Engram/Views/SessionDetailView.swift`

- [ ] **Step 1: Implement Copy All**

```swift
func copyAllTranscript() {
    let text = displayIndexed.map { idx in
        let prefix: String
        switch idx.messageType {
        case .user:      prefix = "> "
        case .assistant: prefix = ""
        case .tool:      prefix = "› "
        case .error:     prefix = "! "
        case .code:      prefix = "```\n"
        }
        return prefix + idx.message.content
    }.joined(separator: "\n\n")

    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}
```

- [ ] **Step 2: Add remaining keyboard shortcuts**

Via `.onKeyPress` or commands:
- ⌘+ → increase font
- ⌘- → decrease font
- ⌥⌘C → copy all
- Escape → close find bar (when find is open)

- [ ] **Step 3: Build and verify all shortcuts work**

- [ ] **Step 4: Commit**

```bash
git add macos/Engram/Views/SessionDetailView.swift
git commit -m "feat(transcript): add copy-all and keyboard shortcuts"
```

---

## Task 11: Final Integration Test and xcodegen

- [ ] **Step 1: Regenerate Xcode project**

Run: `cd /Users/example/-Code-/coding-memory/macos && xcodegen generate`

Since `xcodegen` uses `createIntermediateGroups: true` and sources are under `Engram/`, all new files in `Views/Transcript/` and `Models/` will be auto-discovered.

- [ ] **Step 2: Full build**

Run: `cd /Users/example/-Code-/coding-memory/macos && xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build 2>&1 | tail -10`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Manual smoke test**

Launch from DerivedData. Verify all PR1 features:
1. Toolbar row 1: ★ favorite | Session/Text/JSON | ID copy | A−/A+ | Copy | Find ⌘F
2. Toolbar row 2: All | User N | Assistant N | Tools N | Error N | Code N chips
3. Color bars: blue/purple/green/red/indigo left borders
4. Find (⌘F): search + highlight + count + prev/next (⌘G/⇧⌘G)
5. Chip toggle: click to hide/show type
6. Chip nav: ∧∨ to jump between messages of same type
7. Font: ⌘+/⌘- and A−/A+ buttons
8. Copy: Copy button and ⌥⌘C
9. Raw mode: Text/JSON modes still work
10. Favorite: ★ toggle works

- [ ] **Step 4: Final commit**

```bash
git add -A
git commit -m "feat(transcript): PR1 complete — interactive transcript browser with toolbar, color bars, find, chips"
```
