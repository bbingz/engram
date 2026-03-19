# Settings Redesign — Design Spec

**Goal:** Refactor the monolithic 1005-line `SettingsView.swift` into 5 focused sub-views with `SectionHeader` dividers, matching the app's existing page layout pattern (ScrollView + VStack). No secondary navigation — single-page scroll.

**Scope:** Internal restructure with visual change (Form → ScrollView+VStack). Zero changes to external interfaces (`App.swift`, `MainWindowView.swift`, `MenuBarController`). The layout shifts from `Form(.grouped)` auto-styled rows to manually laid out `HStack` rows with `SectionHeader` dividers — matching the rest of the app's pages.

---

## Architecture

### File Structure

```
Views/
  SettingsView.swift                    — Shell: ScrollView + 5 Section Views (~60 lines)
  Settings/
    SettingsIO.swift                    — Shared settings.json read/write functions (~40 lines)
    GeneralSettingsSection.swift        — Display + Launch + Infrastructure (~120 lines)
    AISettingsSection.swift             — AI Summary full config (~250 lines)
    SourcesSettingsSection.swift        — Data source paths + MCP setup (~200 lines)
    NetworkSettingsSection.swift        — Sync + OpenViking (~180 lines)
    AboutSettingsSection.swift          — Database info + version (~60 lines)
```

### Layout

- **Container**: `ScrollView { VStack(alignment: .leading, spacing: 24) { ... } .padding(24) }`
- **Width**: Remove the fixed `.frame(width: 520)` from the old Form. Let the ScrollView be flexible within NavigationSplitView's detail area (same as other pages). For the standalone Settings window (`MenuBarController.openSettings()`), the window frame already constrains width.
- **Section dividers**: Each sub-view starts with a `SectionHeader` (icon + title), consistent with Home, Activity, SourcePulse, etc.
- **Row styling**: `HStack` with label on the left, control on the right — manually laid out (replacing Form's auto-alignment). This is a visual change from the grouped Form style.
- **Visual change note**: The Form → ScrollView+VStack transition changes the look from macOS grouped-form style to the flat section style used by all other pages in the app. This is intentional for visual consistency.

### State Management

- `@AppStorage` properties live in each sub-view (closest to usage)
- `settings.json` read/write extracted to `SettingsIO.swift`:
  - `func readSettings() -> [String: Any]`
  - `func mutateSettings(_ transform: (inout [String: Any]) -> Void)`
- Load/save methods (`loadAISettings`, `saveAISettings`, etc.) stay with their respective sub-views
- Each sub-view manages its own `onAppear` for loading

### Environment Dependencies

- `@EnvironmentObject var indexer: IndexerProcess` — used by GeneralSettingsSection (status display)
- `@EnvironmentObject var db: DatabaseManager` — used by AboutSettingsSection (session count)
- `@EnvironmentObject var daemonClient: DaemonClient` — not currently consumed by sub-views, but injected by parent callers (`App.swift`, `MenuBarController`). Must remain in the environment chain for forward compatibility.
- All injected at `SettingsView` level, propagate automatically to children

---

## Content Assignment

### GeneralSettingsSection (通用)

| Setting | Type | Storage |
|---------|------|---------|
| Content font size | Slider (10-22pt) | AppStorage |
| Show system prompts | Toggle | AppStorage |
| Show agent communications | Toggle | AppStorage |
| Noise filter | Picker (all/hide-skip/hide-noise) | settings.json |
| Show Dock icon | Toggle | AppStorage |
| Launch at login | Toggle | LaunchAgent |
| HTTP port | TextField | AppStorage |
| MCP HTTP endpoint | Display (`http://localhost:{port}/mcp`) | derived from httpPort |
| Node.js path | TextField | AppStorage |
| Indexer status | Display only | EnvironmentObject |

**External dependencies**: `LaunchAgent` enum (already in `Core/LaunchAgent.swift`, not moved)

### AISettingsSection (AI 摘要)

| Setting | Type | Storage |
|---------|------|---------|
| Protocol | Segmented (openai/anthropic/gemini) | settings.json |
| Base URL | TextField | settings.json |
| API Key | SecureField | settings.json |
| Model | TextField | settings.json |
| Summary language | Picker (中文/English/日本語) | settings.json |
| Max sentences | Stepper (1-10) | settings.json |
| Style | TextField | settings.json |
| Custom prompt | TextEditor (DisclosureGroup) | settings.json |
| Preset | Segmented (concise/standard/detailed) | settings.json |
| Max tokens | Int field (DisclosureGroup) | settings.json |
| Temperature | Slider (0-1) (DisclosureGroup) | settings.json |
| Sample first/last | Int fields (DisclosureGroup) | settings.json |
| Truncate chars | Int field (DisclosureGroup) | settings.json |
| Auto-summary | Toggle | settings.json |
| Auto-summary cooldown | Stepper (1-30 min) | settings.json |
| Auto-summary min messages | Stepper (1-50) | settings.json |
| Auto-summary refresh | Toggle + threshold stepper | settings.json |

### SourcesSettingsSection (数据源)

| Setting | Type | Storage |
|---------|------|---------|
| 13 adapter paths | TextField + PathExistsIndicator | UserDefaults |
| MCP client setup | MCPSetupGuideView (4 clients) | Display + copy |
| MCP script path | TextField (internal to MCPSetupGuideView) | AppStorage |

**Bundled types**: `DataSourceDef`, `DataSourceRow`, `PathExistsIndicator`, `MCPClientDef`, `MCPClientRow`, `MCPSetupGuideView`

### NetworkSettingsSection (网络)

| Setting | Type | Storage |
|---------|------|---------|
| Sync enabled | Toggle | settings.json |
| Sync node name | TextField | settings.json |
| Sync interval | Int field (min 1) | settings.json |
| Sync peers | List + add/delete | settings.json |
| Sync Now button | Button → POST /api/sync/trigger | — |
| Viking enabled | Toggle | settings.json |
| Viking URL | TextField | settings.json |
| Viking API Key | SecureField | settings.json |
| Test Connection | Button → GET health | — |

### AboutSettingsSection (关于)

| Item | Type |
|------|------|
| Database path | Display |
| Database file size | Display (MB) |
| Session count | Display (from db) |
| App version | Display (Bundle.main) |

**Bundled types**: `DatabaseInfoView`

---

## Compatibility — Zero External Changes

| File | Change |
|------|--------|
| `App.swift` | None — `Settings { SettingsView() }` unchanged |
| `MainWindowView.swift` | None — `case .settings: SettingsView()` unchanged |
| `MenuBarController.swift` | None — `openSettings()` creates `SettingsView()` unchanged |
| `project.yml` | None — xcodegen auto-discovers new files in `Views/Settings/` |

---

## Implementation Notes

- Run `xcodegen generate` after creating `Views/Settings/` directory and files
- Each sub-view is a standalone `struct: View` — no protocols or generics needed
- `SectionHeader` component already exists in `Components/SectionHeader.swift`
- The `dataSources` array (top-level constant) moves to `SourcesSettingsSection.swift`
- `defaultBaseURL(for:)` helper moves to `AISettingsSection.swift`
- `noiseFilterDescription` computed property moves to `GeneralSettingsSection.swift`
- `checkVikingStatus()` and `triggerSync()` async functions move to `NetworkSettingsSection.swift`
- DisclosureGroup patterns in AI section preserved as-is
- Peer management UI (add/delete inline form) preserved as-is in NetworkSettingsSection
