# Settings Redesign — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split the monolithic 1005-line `SettingsView.swift` into 5 focused section sub-views with SectionHeader dividers, matching the app's ScrollView+VStack page pattern.

**Architecture:** Extract shared `readSettings`/`mutateSettings` to `SettingsIO.swift`, then create 5 section views (`GeneralSettingsSection`, `AISettingsSection`, `SourcesSettingsSection`, `NetworkSettingsSection`, `AboutSettingsSection`), each owning its own state and load/save logic. Finally, rewrite the shell `SettingsView` to compose them in a ScrollView.

**Build order constraint:** Tasks 1-4 create files with no duplicate type definitions (safe to build alongside old SettingsView.swift). Task 5 atomically creates SourcesSettingsSection + AboutSettingsSection + rewrites the shell — these must happen together because they move types (`DataSourceDef`, `PathExistsIndicator`, `DatabaseInfoView`, etc.) out of the old file.

**Tech Stack:** Swift 5.9 / SwiftUI / macOS 14+ / xcodegen

**Spec:** `docs/superpowers/specs/2026-03-19-settings-redesign-design.md`

---

## File Structure

### New Files

| File | Responsibility |
|------|---------------|
| `Views/Settings/SettingsIO.swift` | Shared `readEngramSettings()`/`mutateEngramSettings()` + `engramSettingsPath` constant |
| `Views/Settings/GeneralSettingsSection.swift` | Display, Session Filter, MCP Server, Node.js Indexer, Launch, MCP endpoint |
| `Views/Settings/AISettingsSection.swift` | AI Summary provider, prompt template, generation config, auto-summary |
| `Views/Settings/NetworkSettingsSection.swift` | Sync config + peer management + OpenViking config + test connection |
| `Views/Settings/SourcesSettingsSection.swift` | 13 data source paths + MCP client setup. Bundles `DataSourceDef`, `DataSourceRow`, `PathExistsIndicator`, `MCPClientDef`, `MCPClientRow`, `MCPSetupGuideView` |
| `Views/Settings/AboutSettingsSection.swift` | Database info + app version. Bundles `DatabaseInfoView` |

### Modified Files

| File | Change |
|------|--------|
| `Views/SettingsView.swift` | Rewrite from 1005 lines to ~20-line shell: ScrollView + 5 section views |

### Unchanged Files (verified)

| File | Reason |
|------|--------|
| `App.swift` | `Settings { SettingsView() }` — unchanged interface |
| `Views/MainWindowView.swift` | `case .settings: SettingsView()` — unchanged interface |
| `MenuBarController.swift` | `openSettings()` creates `SettingsView()` — unchanged interface |
| `project.yml` | xcodegen auto-discovers `.swift` files in `Views/Settings/` |

---

## Task 1: Create SettingsIO — Shared Read/Write

**Files:**
- Create: `macos/Engram/Views/Settings/SettingsIO.swift`

- [ ] **Step 1: Create the directory**

```bash
mkdir -p /Users/bing/-Code-/coding-memory/macos/Engram/Views/Settings
```

- [ ] **Step 2: Create SettingsIO.swift**

Extract `settingsPath`, `readSettings()`, and `mutateSettings()` from `SettingsView.swift` (lines 531-552) as top-level internal functions. Renamed to `readEngramSettings`/`mutateEngramSettings` to avoid name collisions at module scope. The old `SettingsView.swift` still has its own `private` versions — no conflict.

```swift
// macos/Engram/Views/Settings/SettingsIO.swift
import Foundation

let engramSettingsPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".engram/settings.json")

func readEngramSettings() -> [String: Any]? {
    guard let data = try? Data(contentsOf: engramSettingsPath),
          let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }
    return settings
}

func mutateEngramSettings(_ transform: (inout [String: Any]) -> Void) {
    var settings: [String: Any] = [:]
    if let data = try? Data(contentsOf: engramSettingsPath),
       let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        settings = existing
    }
    transform(&settings)
    if let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: engramSettingsPath)
    }
}
```

- [ ] **Step 3: Build to verify**

```bash
cd /Users/bing/-Code-/coding-memory/macos && xcodegen generate && xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add macos/Engram/Views/Settings/SettingsIO.swift
git commit -m "refactor(macos): extract SettingsIO shared read/write functions"
```

---

## Task 2: Create GeneralSettingsSection

**Files:**
- Create: `macos/Engram/Views/Settings/GeneralSettingsSection.swift`

No duplicate types — this view only uses `SectionHeader` (from Components/), `LaunchAgent` (from Core/), and `IndexerProcess` (from Core/). Safe to build alongside old SettingsView.swift.

Extracts from original: Display section (lines 92-118), Session Filter (lines 120-132), MCP Server (lines 134-142), Node.js Indexer (lines 143-156), Launch (lines 168-182), and the "About" section's MCP endpoint display (lines 183-191 — this goes into General/Infrastructure, not About).

- [ ] **Step 1: Create GeneralSettingsSection.swift**

```swift
// macos/Engram/Views/Settings/GeneralSettingsSection.swift
import SwiftUI

struct GeneralSettingsSection: View {
    @AppStorage("contentFontSize") var contentFontSize: Double = 14
    @AppStorage("showSystemPrompts") var showSystemPrompts: Bool = false
    @AppStorage("showAgentComm") var showAgentComm: Bool = false
    @AppStorage("showDockIcon") var showDockIcon: Bool = false
    @AppStorage("httpPort") var httpPort: Int = 3456
    @AppStorage("nodejsPath") var nodejsPath: String = "/usr/local/bin/node"

    @EnvironmentObject var indexer: IndexerProcess

    @State private var noiseFilter: String = "hide-skip"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(icon: "gear", title: "General")

            // Display
            GroupBox("Display") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Content Font Size")
                        Spacer()
                        Slider(value: $contentFontSize, in: 10...22, step: 1) { EmptyView() }
                            .frame(width: 160)
                        Text(verbatim: "\(Int(contentFontSize)) pt")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                    Text("Preview: The quick brown fox jumps over the lazy dog")
                        .font(.system(size: contentFontSize))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Toggle("Show System Prompts", isOn: $showSystemPrompts)
                    Text("CLAUDE.md, AGENTS.md, environment context, and other injected instructions")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Toggle("Show Agent Communication", isOn: $showAgentComm)
                    Text("Tool calls, skill invocations, and command outputs")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 4)
            }

            // Session Filter
            GroupBox("Session Filter") {
                VStack(alignment: .leading, spacing: 6) {
                    Picker("Session Filter", selection: $noiseFilter) {
                        Text("Show All").tag("all")
                        Text("Hide Agents & Noise").tag("hide-skip")
                        Text("Clean View").tag("hide-noise")
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: noiseFilter) { saveNoiseSettings() }

                    Text(noiseFilterDescription)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 4)
            }

            // Infrastructure
            GroupBox("Infrastructure") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("HTTP Port")
                        Spacer()
                        TextField("3456", value: $httpPort, format: .number)
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                    }
                    HStack {
                        Text("MCP HTTP endpoint")
                        Spacer()
                        Text(verbatim: "http://localhost:\(httpPort)/mcp")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    HStack {
                        Text("Node.js Path")
                        Spacer()
                        TextField("/usr/local/bin/node", text: $nodejsPath)
                            .frame(width: 260)
                    }
                    HStack {
                        Text("Status")
                        Spacer()
                        Text(verbatim: indexer.status.displayString)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            // Launch
            GroupBox("Launch") {
                VStack(alignment: .leading, spacing: 10) {
                    if #available(macOS 13.0, *) {
                        Toggle("Launch at Login", isOn: Binding(
                            get: { LaunchAgent.isEnabled },
                            set: { LaunchAgent.setEnabled($0) }
                        ))
                    } else {
                        Text("Login item requires macOS 13+")
                            .foregroundStyle(.secondary)
                    }
                    Toggle("Show Dock Icon", isOn: $showDockIcon)
                    Text("Keep the app icon visible in the Dock at all times")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 4)
            }
        }
        .onAppear { loadNoiseSettings() }
    }

    private var noiseFilterDescription: String {
        switch noiseFilter {
        case "all": return "Show all sessions including agents and noise"
        case "hide-noise": return "Hide agents, empty sessions, and low-signal sessions"
        default: return "Hide sub-agents and trivial sessions (default)"
        }
    }

    private func saveNoiseSettings() {
        mutateEngramSettings { settings in
            settings["noiseFilter"] = noiseFilter
        }
    }

    private func loadNoiseSettings() {
        guard let settings = readEngramSettings() else { return }
        if let v = settings["noiseFilter"] as? String { noiseFilter = v }
    }
}
```

- [ ] **Step 2: Build to verify**

```bash
cd /Users/bing/-Code-/coding-memory/macos && xcodegen generate && xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add macos/Engram/Views/Settings/GeneralSettingsSection.swift
git commit -m "refactor(macos): extract GeneralSettingsSection from SettingsView"
```

---

## Task 3: Create AISettingsSection

**Files:**
- Create: `macos/Engram/Views/Settings/AISettingsSection.swift`

No duplicate types. Extracts from original: AI state vars (lines 31-59), AI Summary/Prompt/Generation/AutoSummary UI (lines 197-351), save/load/helper functions (lines 554-633).

- [ ] **Step 1: Create AISettingsSection.swift**

```swift
// macos/Engram/Views/Settings/AISettingsSection.swift
import SwiftUI

struct AISettingsSection: View {
    // Provider
    @State private var aiProtocol: String = "openai"
    @State private var aiBaseURL: String = ""
    @State private var aiApiKey: String = ""
    @State private var aiModel: String = "gpt-4o-mini"

    // Prompt template
    @State private var summaryLanguage: String = "中文"
    @State private var summaryMaxSentences: Int = 3
    @State private var summaryStyle: String = ""
    @State private var summaryPrompt: String = ""
    @State private var showCustomPrompt: Bool = false

    // Generation config
    @State private var summaryPreset: String = "standard"
    @State private var summaryMaxTokens: Int = 200
    @State private var summaryTemperature: Double = 0.3
    @State private var showCustomGeneration: Bool = false
    @State private var summarySampleFirst: Int = 20
    @State private var summarySampleLast: Int = 30
    @State private var summaryTruncateChars: Int = 500
    @State private var showAdvancedGeneration: Bool = false

    // Auto-summary
    @State private var autoSummary: Bool = false
    @State private var autoSummaryCooldown: Int = 5
    @State private var autoSummaryMinMessages: Int = 4
    @State private var autoSummaryRefresh: Bool = false
    @State private var autoSummaryRefreshThreshold: Int = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(icon: "brain", title: "AI Summary")

            // Provider
            GroupBox("Provider") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Protocol", selection: $aiProtocol) {
                        Text("OpenAI").tag("openai")
                        Text("Anthropic").tag("anthropic")
                        Text("Gemini").tag("gemini")
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: aiProtocol) { saveAISettings() }

                    HStack {
                        Text("Base URL")
                        Spacer()
                        TextField("Default", text: $aiBaseURL)
                            .frame(width: 260)
                            .multilineTextAlignment(.trailing)
                            .onChange(of: aiBaseURL) { saveAISettings() }
                    }
                    Text(defaultBaseURL(for: aiProtocol))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    HStack {
                        Text("API Key")
                        Spacer()
                        SecureField("Required", text: $aiApiKey)
                            .frame(width: 260)
                            .multilineTextAlignment(.trailing)
                            .onChange(of: aiApiKey) { saveAISettings() }
                    }

                    HStack {
                        Text("Model")
                        Spacer()
                        TextField("gpt-4o-mini", text: $aiModel)
                            .frame(width: 260)
                            .multilineTextAlignment(.trailing)
                            .onChange(of: aiModel) { saveAISettings() }
                    }

                    Text("API keys are stored locally in ~/.engram/settings.json")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 4)
            }

            // Prompt Template
            GroupBox("Summary Prompt") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Language", selection: $summaryLanguage) {
                        Text("中文").tag("中文")
                        Text("English").tag("English")
                        Text("日本語").tag("日本語")
                    }
                    .onChange(of: summaryLanguage) { saveAISettings() }

                    Stepper("Max Sentences: \(summaryMaxSentences)", value: $summaryMaxSentences, in: 1...10)
                        .onChange(of: summaryMaxSentences) { saveAISettings() }

                    HStack {
                        Text("Style")
                        Spacer()
                        TextField("Optional, e.g. 技术向", text: $summaryStyle)
                            .frame(width: 260)
                            .multilineTextAlignment(.trailing)
                            .onChange(of: summaryStyle) { saveAISettings() }
                    }

                    DisclosureGroup("Custom Prompt", isExpanded: $showCustomPrompt) {
                        TextEditor(text: $summaryPrompt)
                            .font(.system(.body, design: .monospaced))
                            .frame(height: 80)
                            .onChange(of: summaryPrompt) { saveAISettings() }
                        Text("Variables: {{language}}, {{maxSentences}}, {{style}}")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 4)
            }

            // Generation
            GroupBox("Generation") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Preset", selection: $summaryPreset) {
                        Text("Concise").tag("concise")
                        Text("Standard").tag("standard")
                        Text("Detailed").tag("detailed")
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: summaryPreset) { saveAISettings() }

                    DisclosureGroup("Custom", isExpanded: $showCustomGeneration) {
                        HStack {
                            Text("Max Tokens")
                            Spacer()
                            TextField("200", value: $summaryMaxTokens, format: .number)
                                .frame(width: 80)
                                .multilineTextAlignment(.trailing)
                                .onChange(of: summaryMaxTokens) { saveAISettings() }
                        }
                        HStack {
                            Text("Temperature")
                            Spacer()
                            Slider(value: $summaryTemperature, in: 0...1, step: 0.1)
                                .frame(width: 160)
                                .onChange(of: summaryTemperature) { saveAISettings() }
                            Text(String(format: "%.1f", summaryTemperature))
                                .font(.caption)
                                .frame(width: 30)
                        }
                    }

                    DisclosureGroup("Advanced", isExpanded: $showAdvancedGeneration) {
                        HStack {
                            Text("Sample First")
                            Spacer()
                            TextField("20", value: $summarySampleFirst, format: .number)
                                .frame(width: 60)
                                .multilineTextAlignment(.trailing)
                                .onChange(of: summarySampleFirst) { saveAISettings() }
                            Text("messages")
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Text("Sample Last")
                            Spacer()
                            TextField("30", value: $summarySampleLast, format: .number)
                                .frame(width: 60)
                                .multilineTextAlignment(.trailing)
                                .onChange(of: summarySampleLast) { saveAISettings() }
                            Text("messages")
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Text("Truncate")
                            Spacer()
                            TextField("500", value: $summaryTruncateChars, format: .number)
                                .frame(width: 60)
                                .multilineTextAlignment(.trailing)
                                .onChange(of: summaryTruncateChars) { saveAISettings() }
                            Text("chars/msg")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            // Auto Summary
            GroupBox("Auto Summary") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Auto-generate summaries", isOn: $autoSummary)
                        .onChange(of: autoSummary) { saveAISettings() }
                    if autoSummary {
                        Stepper("Cooldown: \(autoSummaryCooldown) min", value: $autoSummaryCooldown, in: 1...30)
                            .onChange(of: autoSummaryCooldown) { saveAISettings() }
                        Stepper("Min messages: \(autoSummaryMinMessages)", value: $autoSummaryMinMessages, in: 1...50)
                            .onChange(of: autoSummaryMinMessages) { saveAISettings() }
                        Toggle("Periodically refresh", isOn: $autoSummaryRefresh)
                            .onChange(of: autoSummaryRefresh) { saveAISettings() }
                        if autoSummaryRefresh {
                            Stepper("Refresh after \(autoSummaryRefreshThreshold) new messages",
                                    value: $autoSummaryRefreshThreshold, in: 5...100, step: 5)
                                .onChange(of: autoSummaryRefreshThreshold) { saveAISettings() }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .onAppear { loadAISettings() }
    }

    // MARK: - Helpers

    private func defaultBaseURL(for proto: String) -> String {
        switch proto {
        case "anthropic": return "Default: https://api.anthropic.com"
        case "gemini": return "Default: https://generativelanguage.googleapis.com"
        default: return "Default: https://api.openai.com"
        }
    }

    private func saveAISettings() {
        mutateEngramSettings { settings in
            settings["aiProtocol"] = aiProtocol
            if !aiBaseURL.isEmpty { settings["aiBaseURL"] = aiBaseURL } else { settings.removeValue(forKey: "aiBaseURL") }
            settings["aiApiKey"] = aiApiKey
            settings["aiModel"] = aiModel

            settings["summaryLanguage"] = summaryLanguage
            settings["summaryMaxSentences"] = summaryMaxSentences
            if !summaryStyle.isEmpty { settings["summaryStyle"] = summaryStyle } else { settings.removeValue(forKey: "summaryStyle") }
            if !summaryPrompt.isEmpty { settings["summaryPrompt"] = summaryPrompt } else { settings.removeValue(forKey: "summaryPrompt") }

            settings["summaryPreset"] = summaryPreset
            if showCustomGeneration {
                settings["summaryMaxTokens"] = summaryMaxTokens
                settings["summaryTemperature"] = summaryTemperature
            } else {
                settings.removeValue(forKey: "summaryMaxTokens")
                settings.removeValue(forKey: "summaryTemperature")
            }
            if showAdvancedGeneration {
                settings["summarySampleFirst"] = summarySampleFirst
                settings["summarySampleLast"] = summarySampleLast
                settings["summaryTruncateChars"] = summaryTruncateChars
            } else {
                settings.removeValue(forKey: "summarySampleFirst")
                settings.removeValue(forKey: "summarySampleLast")
                settings.removeValue(forKey: "summaryTruncateChars")
            }

            settings["autoSummary"] = autoSummary
            settings["autoSummaryCooldown"] = autoSummaryCooldown
            settings["autoSummaryMinMessages"] = autoSummaryMinMessages
            settings["autoSummaryRefresh"] = autoSummaryRefresh
            settings["autoSummaryRefreshThreshold"] = autoSummaryRefreshThreshold
        }
    }

    private func loadAISettings() {
        guard let settings = readEngramSettings() else { return }

        if let v = settings["aiProtocol"] as? String { aiProtocol = v }
        if let v = settings["aiBaseURL"] as? String { aiBaseURL = v }
        if let v = settings["aiApiKey"] as? String { aiApiKey = v }
        if let v = settings["aiModel"] as? String { aiModel = v }

        if let v = settings["summaryLanguage"] as? String { summaryLanguage = v }
        if let v = settings["summaryMaxSentences"] as? Int { summaryMaxSentences = v }
        if let v = settings["summaryStyle"] as? String { summaryStyle = v }
        if let v = settings["summaryPrompt"] as? String { summaryPrompt = v }

        if let v = settings["summaryPreset"] as? String { summaryPreset = v }
        if let v = settings["summaryMaxTokens"] as? Int { summaryMaxTokens = v; showCustomGeneration = true }
        if let v = settings["summaryTemperature"] as? Double { summaryTemperature = v; showCustomGeneration = true }
        if let v = settings["summarySampleFirst"] as? Int { summarySampleFirst = v; showAdvancedGeneration = true }
        if let v = settings["summarySampleLast"] as? Int { summarySampleLast = v; showAdvancedGeneration = true }
        if let v = settings["summaryTruncateChars"] as? Int { summaryTruncateChars = v; showAdvancedGeneration = true }

        if let v = settings["autoSummary"] as? Bool { autoSummary = v }
        if let v = settings["autoSummaryCooldown"] as? Int { autoSummaryCooldown = v }
        if let v = settings["autoSummaryMinMessages"] as? Int { autoSummaryMinMessages = v }
        if let v = settings["autoSummaryRefresh"] as? Bool { autoSummaryRefresh = v }
        if let v = settings["autoSummaryRefreshThreshold"] as? Int { autoSummaryRefreshThreshold = v }
    }
}
```

- [ ] **Step 2: Build to verify**

```bash
cd /Users/bing/-Code-/coding-memory/macos && xcodegen generate && xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add macos/Engram/Views/Settings/AISettingsSection.swift
git commit -m "refactor(macos): extract AISettingsSection from SettingsView"
```

---

## Task 4: Create NetworkSettingsSection

**Files:**
- Create: `macos/Engram/Views/Settings/NetworkSettingsSection.swift`

No duplicate types. Extracts from original: Sync state (lines 61-79), Viking state (lines 69-74), OpenViking UI (lines 354-397), Sync UI (lines 399-518), save/load (lines 635-677), async functions (lines 698-765).

- [ ] **Step 1: Create NetworkSettingsSection.swift**

```swift
// macos/Engram/Views/Settings/NetworkSettingsSection.swift
import SwiftUI

struct NetworkSettingsSection: View {
    // Sync
    @State private var syncEnabled: Bool = false
    @State private var syncNodeName: String = ""
    @State private var syncPeers: [[String: String]] = []
    @State private var syncIntervalMinutes: Int = 30
    @State private var syncStatus: String = ""
    @State private var isSyncing: Bool = false

    // Viking
    @State private var vikingEnabled: Bool = false
    @State private var vikingURL: String = ""
    @State private var vikingApiKey: String = ""
    @State private var vikingStatus: String = ""
    @State private var isCheckingViking: Bool = false

    // Add peer form
    @State private var showAddPeer: Bool = false
    @State private var newPeerName: String = ""
    @State private var newPeerURL: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(icon: "network", title: "Network")

            // OpenViking
            GroupBox("OpenViking") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Enable", isOn: $vikingEnabled)
                        .onChange(of: vikingEnabled) { saveVikingSettings() }

                    HStack {
                        Text("Server URL")
                        Spacer()
                        TextField("http://localhost:1933", text: $vikingURL)
                            .frame(width: 260)
                            .multilineTextAlignment(.trailing)
                            .onChange(of: vikingURL) { saveVikingSettings() }
                    }

                    HStack {
                        Text("API Key")
                        Spacer()
                        SecureField("Required", text: $vikingApiKey)
                            .frame(width: 260)
                            .multilineTextAlignment(.trailing)
                            .onChange(of: vikingApiKey) { saveVikingSettings() }
                    }

                    HStack {
                        Button {
                            checkVikingStatus()
                        } label: {
                            Text("Test Connection")
                        }
                        .disabled(isCheckingViking || !vikingEnabled || vikingURL.isEmpty)

                        if !vikingStatus.isEmpty {
                            Circle()
                                .fill(vikingStatus == "Connected" ? Color.green : Color.red)
                                .frame(width: 8, height: 8)
                            Text(verbatim: vikingStatus)
                                .font(.caption)
                                .foregroundStyle(vikingStatus == "Connected" ? .green : .red)
                        }
                    }

                    Text("OpenViking enhances search with semantic understanding and tiered summaries")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 4)
            }

            // Sync
            GroupBox("Sync") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Enable Sync", isOn: $syncEnabled)
                        .onChange(of: syncEnabled) { saveSyncSettings() }

                    HStack {
                        Text("Node Name")
                        Spacer()
                        TextField("e.g. macbook-pro", text: $syncNodeName)
                            .frame(width: 200)
                            .multilineTextAlignment(.trailing)
                            .onChange(of: syncNodeName) { saveSyncSettings() }
                    }

                    HStack {
                        Text("Interval (minutes)")
                        Spacer()
                        TextField("30", value: $syncIntervalMinutes, format: .number)
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                            .onChange(of: syncIntervalMinutes) {
                                if syncIntervalMinutes < 1 { syncIntervalMinutes = 1 }
                                saveSyncSettings()
                            }
                    }

                    // Peer list
                    if !syncPeers.isEmpty {
                        ForEach(Array(syncPeers.enumerated()), id: \.offset) { index, peer in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: peer["name"] ?? "")
                                        .font(.caption.bold())
                                    Text(verbatim: peer["url"] ?? "")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(role: .destructive) {
                                    syncPeers.remove(at: index)
                                    saveSyncSettings()
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.caption)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.red)
                            }
                        }
                    }

                    // Add peer
                    if showAddPeer {
                        VStack(spacing: 6) {
                            HStack {
                                Text("Name")
                                    .font(.caption)
                                    .frame(width: 40, alignment: .leading)
                                TextField("e.g. imac-studio", text: $newPeerName)
                                    .font(.caption)
                                    .textFieldStyle(.roundedBorder)
                            }
                            HStack {
                                Text("URL")
                                    .font(.caption)
                                    .frame(width: 40, alignment: .leading)
                                TextField("http://192.168.1.100:3457", text: $newPeerURL)
                                    .font(.caption)
                                    .textFieldStyle(.roundedBorder)
                            }
                            HStack {
                                Button("Cancel") {
                                    showAddPeer = false
                                    newPeerName = ""
                                    newPeerURL = ""
                                }
                                .font(.caption)
                                Spacer()
                                Button("Add") {
                                    if !newPeerName.isEmpty && !newPeerURL.isEmpty {
                                        syncPeers.append(["name": newPeerName, "url": newPeerURL])
                                        saveSyncSettings()
                                        newPeerName = ""
                                        newPeerURL = ""
                                        showAddPeer = false
                                    }
                                }
                                .font(.caption)
                                .disabled(newPeerName.isEmpty || newPeerURL.isEmpty)
                            }
                        }
                        .padding(8)
                        .background(Color.secondary.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    } else {
                        Button("Add Peer") {
                            showAddPeer = true
                        }
                        .font(.caption)
                    }

                    // Sync Now
                    HStack {
                        Button {
                            triggerSync()
                        } label: {
                            Text("Sync Now")
                        }
                        .disabled(isSyncing || !syncEnabled)

                        if !syncStatus.isEmpty {
                            Text(verbatim: syncStatus)
                                .font(.caption)
                                .foregroundStyle(syncStatus == "Failed" ? .red : .secondary)
                        }
                    }

                    Text("Sync settings are stored in ~/.engram/settings.json")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 4)
            }
        }
        .onAppear {
            loadSyncSettings()
            loadVikingSettings()
        }
    }

    // MARK: - Viking

    private func saveVikingSettings() {
        mutateEngramSettings { settings in
            var viking: [String: Any] = [:]
            viking["enabled"] = vikingEnabled
            if !vikingURL.isEmpty { viking["url"] = vikingURL }
            if !vikingApiKey.isEmpty { viking["apiKey"] = vikingApiKey }
            settings["viking"] = viking
        }
    }

    private func loadVikingSettings() {
        guard let settings = readEngramSettings(),
              let viking = settings["viking"] as? [String: Any] else { return }
        if let enabled = viking["enabled"] as? Bool { vikingEnabled = enabled }
        if let url = viking["url"] as? String { vikingURL = url }
        if let key = viking["apiKey"] as? String { vikingApiKey = key }
    }

    private func checkVikingStatus() {
        isCheckingViking = true
        vikingStatus = ""

        guard let url = URL(string: "\(vikingURL)/api/v1/debug/health") else {
            vikingStatus = "Invalid URL"
            isCheckingViking = false
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(vikingApiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 5

        URLSession.shared.dataTask(with: request) { _, response, error in
            DispatchQueue.main.async {
                isCheckingViking = false
                if let error = error {
                    vikingStatus = "Error: \(error.localizedDescription)"
                } else if let httpResponse = response as? HTTPURLResponse,
                          (200...299).contains(httpResponse.statusCode) {
                    vikingStatus = "Connected"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                        if vikingStatus == "Connected" { vikingStatus = "" }
                    }
                } else {
                    vikingStatus = "Unreachable"
                }
            }
        }.resume()
    }

    // MARK: - Sync

    private func saveSyncSettings() {
        mutateEngramSettings { settings in
            settings["syncEnabled"] = syncEnabled
            settings["syncNodeName"] = syncNodeName
            settings["syncIntervalMinutes"] = syncIntervalMinutes
            settings["syncPeers"] = syncPeers
        }
    }

    private func loadSyncSettings() {
        guard let settings = readEngramSettings() else { return }
        if let enabled = settings["syncEnabled"] as? Bool { syncEnabled = enabled }
        if let name = settings["syncNodeName"] as? String { syncNodeName = name }
        if let interval = settings["syncIntervalMinutes"] as? Int { syncIntervalMinutes = interval }
        if let peers = settings["syncPeers"] as? [[String: String]] { syncPeers = peers }
    }

    private func triggerSync() {
        isSyncing = true
        syncStatus = "Syncing..."

        let webPort: Int = (readEngramSettings()?["httpPort"] as? Int) ?? 3457

        guard let url = URL(string: "http://localhost:\(webPort)/api/sync/trigger") else {
            syncStatus = "Failed"
            isSyncing = false
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        URLSession.shared.dataTask(with: request) { _, response, error in
            DispatchQueue.main.async {
                isSyncing = false
                if let error = error {
                    syncStatus = "Failed"
                    print("Sync error: \(error.localizedDescription)")
                } else if let httpResponse = response as? HTTPURLResponse,
                          (200...299).contains(httpResponse.statusCode) {
                    syncStatus = "Synced!"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        if syncStatus == "Synced!" { syncStatus = "" }
                    }
                } else {
                    syncStatus = "Failed"
                }
            }
        }.resume()
    }
}
```

- [ ] **Step 2: Build to verify**

```bash
cd /Users/bing/-Code-/coding-memory/macos && xcodegen generate && xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add macos/Engram/Views/Settings/NetworkSettingsSection.swift
git commit -m "refactor(macos): extract NetworkSettingsSection from SettingsView"
```

---

## Task 5: Create SourcesSettingsSection + AboutSettingsSection + Rewrite Shell (Atomic)

**Files:**
- Create: `macos/Engram/Views/Settings/SourcesSettingsSection.swift`
- Create: `macos/Engram/Views/Settings/AboutSettingsSection.swift`
- Modify: `macos/Engram/Views/SettingsView.swift` (full rewrite)

**Why atomic:** These two section files define types (`DataSourceDef`, `PathExistsIndicator`, `DataSourceRow`, `MCPClientDef`, `MCPClientRow`, `MCPSetupGuideView`, `DatabaseInfoView`) that currently exist in the old `SettingsView.swift`. Creating them without simultaneously removing the old definitions would cause duplicate symbol errors. This task creates both files AND rewrites the shell in one step.

- [ ] **Step 1: Create SourcesSettingsSection.swift**

```swift
// macos/Engram/Views/Settings/SourcesSettingsSection.swift
import SwiftUI

struct DataSourceDef {
    let name: String
    let key: String
    let defaultPath: String
}

private let dataSources: [DataSourceDef] = [
    .init(name: "Claude Code",  key: "path.claude-code",  defaultPath: "~/.claude/projects"),
    .init(name: "Codex",        key: "path.codex",        defaultPath: "~/.codex/sessions"),
    .init(name: "Copilot CLI",  key: "path.copilot",      defaultPath: "~/.copilot/session-state"),
    .init(name: "Gemini CLI",   key: "path.gemini-cli",   defaultPath: "~/.gemini/tmp"),
    .init(name: "OpenCode",     key: "path.opencode",     defaultPath: "~/.local/share/opencode/opencode.db"),
    .init(name: "iFlow",        key: "path.iflow",        defaultPath: "~/.iflow/projects"),
    .init(name: "Qwen",         key: "path.qwen",         defaultPath: "~/.qwen/projects"),
    .init(name: "Kimi",         key: "path.kimi",         defaultPath: "~/.kimi/sessions"),
    .init(name: "Cline",        key: "path.cline",        defaultPath: "~/.cline/data/tasks"),
    .init(name: "Cursor",       key: "path.cursor",       defaultPath: "~/Library/Application Support/Cursor/User/globalStorage/state.vscdb"),
    .init(name: "VS Code",      key: "path.vscode",       defaultPath: "~/Library/Application Support/Code/User/workspaceStorage"),
    .init(name: "Antigravity",  key: "path.antigravity",  defaultPath: "~/.gemini/antigravity/daemon"),
    .init(name: "Windsurf",     key: "path.windsurf",     defaultPath: "~/.codeium/windsurf/daemon"),
]

struct SourcesSettingsSection: View {
    @AppStorage("nodejsPath") var nodejsPath: String = "/usr/local/bin/node"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(icon: "folder", title: "Data Sources")

            GroupBox("Adapter Paths") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(dataSources, id: \.key) { ds in
                        DataSourceRow(def: ds)
                    }
                }
                .padding(.vertical, 4)
            }

            GroupBox("MCP Client Setup") {
                MCPSetupGuideView(nodejsPath: nodejsPath)
                    .padding(.vertical, 4)
            }
        }
    }
}

// MARK: - Path Exists Indicator

struct PathExistsIndicator: View {
    let exists: Bool

    init(exists: Bool) {
        self.exists = exists
    }

    init(path: String) {
        self.exists = FileManager.default.fileExists(atPath: path)
    }

    var body: some View {
        Circle()
            .fill(exists ? Color.green : Color.red)
            .frame(width: 8, height: 8)
            .help(exists ? LocalizedStringKey("Path exists") : LocalizedStringKey("Path not found"))
    }
}

// MARK: - Data Source Row

struct DataSourceRow: View {
    let def: DataSourceDef
    @State private var path: String = ""
    @State private var exists: Bool? = nil

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: def.name)
                .frame(width: 90, alignment: .leading)
            TextField(def.defaultPath, text: $path)
                .font(.caption)
                .textFieldStyle(.roundedBorder)
                .onChange(of: path) { _, newValue in
                    savePath(newValue)
                    checkExists(newValue)
                }
            if let exists {
                PathExistsIndicator(exists: exists)
            }
        }
        .onAppear {
            path = UserDefaults.standard.string(forKey: def.key) ?? def.defaultPath
            checkExists(path)
        }
    }

    private func savePath(_ value: String) {
        if value == def.defaultPath {
            UserDefaults.standard.removeObject(forKey: def.key)
        } else {
            UserDefaults.standard.set(value, forKey: def.key)
        }
    }

    private func checkExists(_ rawPath: String) {
        let expanded = (rawPath as NSString).expandingTildeInPath
        exists = FileManager.default.fileExists(atPath: expanded)
    }
}

// MARK: - MCP Setup Guide

struct MCPClientDef {
    let name: String
    let configPath: String
    let snippet: (String, String) -> String
}

struct MCPSetupGuideView: View {
    let nodejsPath: String
    @AppStorage("mcpScriptPath") var scriptPath: String = "~/.engram/dist/index.js"

    private var resolvedScript: String {
        (scriptPath as NSString).expandingTildeInPath
    }

    private static let clients: [MCPClientDef] = [
        MCPClientDef(
            name: "Claude Code",
            configPath: "~/.claude.json or: claude mcp add",
            snippet: { node, script in
                "claude mcp add engram \(node) \(script)"
            }
        ),
        MCPClientDef(
            name: "Gemini CLI",
            configPath: "~/.gemini/settings.json",
            snippet: { node, script in
                """
                "engram": {
                  "command": "\(node)",
                  "args": ["\(script)"],
                  "trust": true
                }
                """
            }
        ),
        MCPClientDef(
            name: "Codex CLI",
            configPath: "~/.codex/config.yaml or: codex --mcp",
            snippet: { node, script in
                "codex --mcp-server \(node) \(script)"
            }
        ),
        MCPClientDef(
            name: "Cursor / VS Code",
            configPath: ".cursor/mcp.json or .vscode/mcp.json",
            snippet: { node, script in
                """
                "engram": {
                  "command": "\(node)",
                  "args": ["\(script)"]
                }
                """
            }
        ),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("MCP Script")
                    .frame(width: 90, alignment: .leading)
                TextField("~/.engram/dist/index.js", text: $scriptPath)
                    .font(.caption)
                    .textFieldStyle(.roundedBorder)
                PathExistsIndicator(path: resolvedScript)
            }
            Text("Add engram to your MCP clients using the configurations below.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(Self.clients, id: \.name) { client in
                MCPClientRow(client: client, nodePath: nodejsPath, scriptPath: resolvedScript)
            }
        }
    }
}

struct MCPClientRow: View {
    let client: MCPClientDef
    let nodePath: String
    let scriptPath: String
    @State private var copied = false

    private var snippet: String {
        client.snippet(nodePath, scriptPath)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(verbatim: client.name)
                    .font(.caption.bold())
                Text(verbatim: client.configPath)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(snippet, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Text(copied ? LocalizedStringKey("Copied!") : LocalizedStringKey("Copy"))
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(copied ? Color.green.opacity(0.15) : Color.secondary.opacity(0.1))
                        .foregroundStyle(copied ? .green : .secondary)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
            }
            Text(verbatim: snippet)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }
}
```

- [ ] **Step 2: Create AboutSettingsSection.swift**

```swift
// macos/Engram/Views/Settings/AboutSettingsSection.swift
import SwiftUI

struct AboutSettingsSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(icon: "info.circle", title: "About")

            GroupBox("Database") {
                DatabaseInfoView()
                    .padding(.vertical, 4)
            }

            GroupBox("App") {
                HStack {
                    Text("Version")
                    Spacer()
                    Text(verbatim: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
    }
}

// MARK: - Database Info

struct DatabaseInfoView: View {
    @EnvironmentObject var db: DatabaseManager
    @State private var dbSize: String = "..."
    @State private var sessionCount: String = "..."
    private let dbPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".engram/index.sqlite").path

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Path")
                Spacer()
                Text(verbatim: dbPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack {
                Text("Size")
                Spacer()
                Text(verbatim: dbSize)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("Sessions")
                Spacer()
                Text(verbatim: sessionCount)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { loadInfo() }
    }

    private func loadInfo() {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: dbPath),
           let size = attrs[.size] as? Int {
            let mb = Double(size) / 1024 / 1024
            dbSize = String(format: "%.1f MB", mb)
        } else {
            dbSize = "N/A"
        }
        sessionCount = "\((try? db.countSessions()) ?? 0)"
    }
}
```

- [ ] **Step 3: Rewrite SettingsView.swift as thin shell**

Replace the entire contents of `macos/Engram/Views/SettingsView.swift` with:

```swift
// macos/Engram/Views/SettingsView.swift
import SwiftUI

struct SettingsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                GeneralSettingsSection()
                AISettingsSection()
                SourcesSettingsSection()
                NetworkSettingsSection()
                AboutSettingsSection()
            }
            .padding(24)
        }
        .frame(minWidth: 480, minHeight: 400)
    }
}
```

- [ ] **Step 4: Regenerate Xcode project and build**

```bash
cd /Users/bing/-Code-/coding-memory/macos && xcodegen generate && xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build 2>&1 | tail -20
```

Expected: BUILD SUCCEEDED with zero duplicate symbol errors.

- [ ] **Step 5: Fix any build errors**

If duplicate symbols: verify each type exists in exactly one file:
- `DataSourceDef`, `DataSourceRow`, `PathExistsIndicator`, `MCPClientDef`, `MCPClientRow`, `MCPSetupGuideView` → `SourcesSettingsSection.swift` only
- `DatabaseInfoView` → `AboutSettingsSection.swift` only
- Old `SettingsView.swift` should be ~15 lines, no type definitions

- [ ] **Step 6: Commit**

```bash
git add macos/Engram/Views/Settings/SourcesSettingsSection.swift macos/Engram/Views/Settings/AboutSettingsSection.swift macos/Engram/Views/SettingsView.swift
git commit -m "refactor(macos): extract Sources + About sections, rewrite SettingsView as thin shell"
```

---

## Task 6: Final Verification

- [ ] **Step 1: Full clean build**

```bash
cd /Users/bing/-Code-/coding-memory/macos && xcodegen generate && xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug clean build 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED

- [ ] **Step 2: TypeScript tests (ensure no regressions)**

```bash
cd /Users/bing/-Code-/coding-memory && npm test 2>&1 | tail -5
```

Expected: All tests pass (no Swift changes affect TS).

- [ ] **Step 3: Launch and verify**

```bash
open ~/Library/Developer/Xcode/DerivedData/Engram-*/Build/Products/Debug/Engram.app
```

Verify:
- Settings page renders in the main window (sidebar → Settings)
- All 5 sections visible with SectionHeader dividers
- Settings still opens from menu bar right-click → Settings
- Cmd+, opens native Settings window
- Each section's controls work (toggles, pickers, text fields)
- AI settings load/save correctly
- Sync/Viking settings load/save correctly
- Data source paths show green/red indicators
- MCP setup copy buttons work

- [ ] **Step 4: Commit verification result**

No commit needed — this is verification only. If issues found, fix and commit the fix.
