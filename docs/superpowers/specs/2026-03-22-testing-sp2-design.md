# Testing Sub-Project 2: XCUITest UI Automation + Screenshot Regression

- **Date**: 2026-03-22
- **Status**: Draft
- **Scope**: 59 XCUITest cases across 15 pages + popover, Node-based screenshot comparison with pHash+SSIM+pixelmatch, Git LFS baseline management, CI smoke/full pipeline
- **Dependencies**: SP1 (fixture DB, AppEnvironment, Swift unit tests, CI pipeline)
- **Followed by**: SP3 (E2E full-chain testing, AI triage, release gating)

## Problem

Engram's macOS app has 91 Swift files (~13K LOC), 15 page screens, a menu bar popover, and 17 reusable components. SP1 established unit tests for Core/Models/Components but no UI-level testing exists. Visual regressions — broken layouts, missing data, theme inconsistencies — can only be caught by manual inspection. There's no automated way to verify that the app's screens render correctly after code changes.

## Goals

1. Full XCUITest coverage: 59 tests across all 15 pages + popover + navigation
2. Screenshot regression pipeline: capture PNGs in Swift, compare in Node (pixelmatch + ssim.js + imghash)
3. Git LFS baseline management with CLI update workflow
4. CI integration: PR smoke tests (~15 core tests), main branch full suite (59 tests)
5. Structured comparison report (JSON) with SP3 AI triage field pre-reserved
6. Popover testable via `--popover-standalone` mode

## Non-Goals

- AI-powered triage (SP3 — but report format is designed for it)
- E2E daemon ↔ Swift integration tests (SP3)
- Release pipeline / gating (SP3)
- Performance benchmarking of UI rendering
- Accessibility compliance testing (potential future SP)

---

## Layer 1: App Test Mode Enhancements

### 1.1 Launch Arguments

SP1 established `AppEnvironment` with `--test-mode` and `--fixture-db` support. SP2 adds:

| Argument | Purpose |
|----------|---------|
| `--popover-standalone` | Render PopoverView in a standard NSWindow (400×600) instead of menu bar NSPopover |
| `--fixed-date 2026-01-15T10:00:00Z` | Deterministic timestamps — overrides `AppEnvironment.test()` hardcoded date (see parsing below) |
| `--window-size 1280x800` | Fixed main window size for consistent screenshots (parsed in `AppEnvironment`, applied in `MenuBarController.openWindow()`) |
| `--mock-daemon` | DaemonClient returns fixture JSON instead of HTTP calls (see 1.2) |
| `--appearance dark\|light` | Override system appearance (applied via `NSApp.appearance` in AppDelegate) |

**`--fixed-date` parsing** in `AppEnvironment.fromCommandLine()`:

```swift
static func fromCommandLine() -> AppEnvironment {
    // ... existing --test-mode / --fixture-db parsing ...

    // Override fixedDate if --fixed-date is provided
    var fixedDate = Date(timeIntervalSince1970: 1742601600) // default: 2025-03-22
    if let idx = CommandLine.arguments.firstIndex(of: "--fixed-date"),
       CommandLine.arguments.indices.contains(idx + 1) {
        let fmt = ISO8601DateFormatter()
        fixedDate = fmt.date(from: CommandLine.arguments[idx + 1]) ?? fixedDate
    }
    // Pass fixedDate to AppEnvironment init
}
```

### 1.2 MockDaemonClient

~30% of views (SourcePulse, Memory, Skills, Hooks) fetch data via `DaemonClient` HTTP calls to `localhost:3457`. In test mode, these must return deterministic fixture data without a running daemon.

**Process boundary**: XCUITest runs in a separate process from the app under test. The mock must be compiled into the **app target** and activated via launch arguments — the UI test process cannot inject mocks at runtime.

```swift
// DaemonClient.swift — test mode branch (in app target, #if DEBUG)
#if DEBUG
class DaemonClient: ObservableObject {
    var testMode: Bool = false  // Set by AppDelegate when --mock-daemon is passed

    func fetch<T: Decodable>(_ endpoint: String) async throws -> T {
        if testMode {
            return try mockResponse(for: endpoint)
        }
        // ... real HTTP call
    }

    private func mockResponse<T: Decodable>(for endpoint: String) throws -> T {
        let json = MockDaemonFixtures.response(for: endpoint)
        return try JSONDecoder().decode(T.self, from: json)
    }
}
#endif
```

**Activation**: `AppDelegate.applicationDidFinishLaunching()` parses `--mock-daemon` from launch arguments, sets `daemonClient.testMode = true`.

`MockDaemonFixtures` lives in `macos/Engram/Core/MockDaemonFixtures.swift` (app target, `#if DEBUG`) — hardcoded JSON responses:
- `/api/live` → 2 mock active sessions
- `/api/memory` → 3 mock memory entries
- `/api/skills` → empty list
- `/api/hooks` → 2 mock hooks

### 1.3 Fixture DB Expansion

The SP1 fixture DB (`test-fixtures/test-index.sqlite`, 20 sessions) needs additional seed data for Observability and Repos pages:

| Table | Seed Count | Purpose |
|-------|-----------|---------|
| `git_repos` | 3 | ReposView sparklines, RepoDetailView |
| `logs` | 5 | LogStreamView rendering |
| `traces` | 3 | TraceExplorerView rendering |
| `metrics` | 5 | PerformanceView charts |

Added to `scripts/generate-test-fixtures.ts`. Minimal data — enough to verify non-empty rendering. Empty state testing uses filter combinations that yield 0 results.

### 1.4 Popover Standalone Mode

The main window and popover are created programmatically via `MenuBarController` using `NSWindow` and `NSPopover` — not SwiftUI `Scene` declarations. The standalone mode follows the same programmatic pattern:

```swift
// In AppDelegate.applicationDidFinishLaunching()
if environment.popoverStandalone {
    // Skip MenuBarController + NSStatusItem entirely
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 400, height: 600),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )
    // PopoverView requires @EnvironmentObject var db: DatabaseManager
    // and @EnvironmentObject var indexer: IndexerProcess
    window.contentView = NSHostingView(rootView: PopoverView()
        .environmentObject(db)
        .environmentObject(indexer))
    window.title = "Popover Preview"
    window.center()
    window.makeKeyAndOrderFront(nil)
    window.setContentSize(NSSize(width: 400, height: 600))
    // Prevent resize to keep screenshot dimensions consistent
    window.styleMask.remove(.resizable)
} else {
    // Normal MenuBarController + main window flow
}
```

- Skips `NSStatusItem` and `MenuBarController` creation entirely:
  ```swift
  // In applicationDidFinishLaunching:
  if environment.popoverStandalone {
      // standalone window setup (above)
  } else {
      menuBarController = MenuBarController(db: db, indexer: indexer, daemonClient: daemonClient)
  }
  ```
- Same data sources (fixture DB + MockDaemonClient)
- Fixed 400×600 size, non-resizable for consistent screenshots
- Screenshots named with `popover_` prefix

---

## Layer 2: Page Object Pattern + Accessibility Identifiers

### 2.1 Accessibility Identifier Convention

All testable views need `.accessibilityIdentifier()` modifiers. Naming convention:

```
{page}_{element}_{qualifier}
```

Examples:
- `home_kpiCard_sessions` — Home page, KPI card showing session count
- `sessions_filterPill_today` — Sessions page, "Today" filter pill
- `sessions_row_0` — Sessions page, first row in list
- `sidebar_item_home` — Sidebar navigation item for Home
- `popover_statsGrid` — Popover stats grid container

**Scope**: ~53 view files need identifier additions. Priority order:
1. Core path views (Home, Sessions, SessionDetail, Search, Settings) — required for smoke tests
2. Data-dense views (Activity, Timeline, SourcePulse, Projects)
3. Remaining views (Observability, Repos, Agents, Memory, Hooks, Skills)
4. Shared components (SessionCard, KPICard, FilterPills, etc.)

### 2.2 Page Object Structure

```
macos/EngramUITests/
├── Screens/                    # Page Objects
│   ├── HomeScreen.swift
│   ├── SessionsScreen.swift
│   ├── SessionDetailScreen.swift
│   ├── SearchScreen.swift
│   ├── SettingsScreen.swift
│   ├── ActivityScreen.swift
│   ├── TimelineScreen.swift
│   ├── SourcePulseScreen.swift
│   ├── ProjectsScreen.swift
│   ├── ObservabilityScreen.swift
│   ├── ReposScreen.swift
│   ├── AgentsScreen.swift
│   ├── MemoryScreen.swift
│   ├── HooksScreen.swift
│   ├── SkillsScreen.swift
│   ├── PopoverScreen.swift
│   └── SidebarScreen.swift
├── Helpers/
│   ├── TestLaunchConfig.swift  # Launch argument configuration
│   ├── ScreenshotCapture.swift # Screenshot utility + manifest writer
│   └── WaitUtils.swift         # Explicit waits for async data loading
│   # MockDaemonFixtures → app target: Engram/Core/MockDaemonFixtures.swift (see 1.2)
├── Tests/
│   ├── SmokeTests/             # ~15 tests (PR trigger)
│   │   ├── HomeSmokeTests.swift
│   │   ├── SessionsSmokeTests.swift
│   │   ├── SessionDetailSmokeTests.swift
│   │   ├── SearchSmokeTests.swift
│   │   ├── NavigationSmokeTests.swift
│   │   ├── PopoverSmokeTests.swift
│   │   └── ActivitySmokeTests.swift
│   └── FullTests/              # All tests (main branch trigger)
│       ├── HomeTests.swift
│       ├── SessionsTests.swift
│       ├── ... (one per page)
│       └── DarkModeTests.swift
└── baselines/                  # Git LFS tracked PNGs
    ├── home_kpi_cards.png
    ├── home_kpi_cards_dark.png
    └── ...
```

### 2.3 Page Object Example

**Important**: SwiftUI view types map to different XCUIElement types than UIKit. Before writing page objects, run Accessibility Inspector on each page to determine the correct element types. Common mappings:
- `List` → `app.tables` / `app.outlines`
- `ScrollView` + `LazyVStack` → `app.scrollViews`
- `Button` → `app.buttons`
- `Text` → `app.staticTexts`
- `TextField` → `app.textFields`
- `NavigationSplitView` sidebar → `app.outlines` or `app.tables`

```swift
struct SessionsScreen {
    let app: XCUIApplication

    // Elements — use Accessibility Inspector to verify correct element types
    // SessionsPageView uses ScrollView + LazyVStack, NOT List/Table
    var sessionList: XCUIElement { app.scrollViews["sessions_list"] }
    var filterPills: XCUIElement { app.groups["sessions_filterPills"] }
    var searchField: XCUIElement { app.searchFields["sessions_projectSearch"] }
    var sortMenu: XCUIElement { app.popUpButtons["sessions_sortMenu"] }
    var sessionCount: XCUIElement { app.staticTexts["sessions_count"] }

    // Actions
    func selectSession(at index: Int) -> SessionDetailScreen {
        app.otherElements["sessions_row_\(index)"].tap()
        return SessionDetailScreen(app: app)
    }

    func applyFilter(_ name: String) {
        app.buttons["sessions_filterPill_\(name)"].tap()
    }

    func waitForLoad(timeout: TimeInterval = 5) {
        _ = sessionList.waitForExistence(timeout: timeout)
    }
}
```

---

## Layer 3: Test Coverage Matrix

### 3.1 Full Coverage (59 tests)

| Page | Type | Tests | Coverage | Screenshot |
|------|------|-------|----------|------------|
| **Home** | Core | 5 | KPI cards render with data, daily chart, hourly chart, source distribution, recent sessions list | 3 shots |
| **Sessions** | Core+Data | 6 | List loads with 20 sessions, "Today" filter applied, source filter, sort by duration, pagination, empty filter result | 4 shots |
| **SessionDetail** | Core | 5 | Transcript renders messages, message type chips visible, metadata panel, find bar (Cmd+F), tool calls expanded | 3 shots |
| **Search** | Core | 4 | Search input + execute, results list, result click → detail navigation, no results state | 2 shots |
| **Settings** | Core | 4 | 5 section tabs navigable, General toggles, OpenViking config fields, About section info | 3 shots |
| **Activity** | Data | 3 | Daily activity chart, hourly heatmap, source breakdown | 2 shots |
| **Timeline** | Data | 3 | Timeline renders sessions, date navigation, session node click | 2 shots |
| **SourcePulse** | Data | 3 | Source status indicators, health dashboard, stale source highlight | 2 shots |
| **Projects** | Data | 3 | Project list, per-project session group, empty project | 2 shots |
| **Observability** | Normal | 5 | Log stream, trace explorer, error dashboard, performance charts, system health | 3 shots |
| **Repos** | Normal | 2 | Repo list with sparklines, repo detail | 2 shots |
| **Agents** | Normal | 2 | Agent filter, agent session list | 1 shot |
| **Memory** | Normal | 2 | Entry list, search | 1 shot |
| **Hooks** | Normal | 2 | Hook list, hook detail | 1 shot |
| **Skills** | Normal | 2 | Skills list display | 1 shot |
| **Popover** | Core | 3 | Status indicators, stats grid, recent activity | 2 shots |
| **Navigation** | Core | 2 | Sidebar full traversal, Command Palette open/search | 1 shot |
| **Dark Mode** | Core | 5 | Home, Sessions, SessionDetail, Settings, Popover (dark variants) | 5 shots |
| | | **59** | | **39 baseline screenshots** |

### 3.2 Smoke Subset (PR trigger, ~15 tests)

```
Home(2) + Sessions(3) + SessionDetail(2) + Search(2) + Settings(1) +
Navigation(2) + Popover(1) + Activity(1) + Timeline(1) = 15 tests
```

Smoke tests are a subset of full tests — same test classes, filtered by `-only-testing:EngramUITests/SmokeTests`.

### 3.3 Dark Mode Strategy

Only 5 key pages tested in dark mode (not all 15):
- Home, Sessions, SessionDetail, Settings, Popover

Implementation: `DarkModeTests.swift` sets appearance before launch:

```swift
func testHomePageDarkMode() throws {
    app.launchArguments += ["--appearance", "dark"]
    app.launch()
    // Navigate to Home, capture screenshot with "_dark" suffix
}
```

**Appearance override implementation** (in `AppDelegate.applicationDidFinishLaunching()`, not `AppEnvironment`):

```swift
if let idx = CommandLine.arguments.firstIndex(of: "--appearance"),
   CommandLine.arguments.indices.contains(idx + 1) {
    let name: NSAppearance.Name = CommandLine.arguments[idx + 1] == "dark"
        ? .darkAqua : .aqua
    NSApp.appearance = NSAppearance(named: name)
}
```

This uses `NSApp.appearance` (AppKit) rather than SwiftUI's `.preferredColorScheme()` because the app uses programmatic `NSWindow` creation.

---

## Layer 4: Screenshot Comparison Pipeline

### 4.1 Capture (Swift)

```swift
// ScreenshotCapture.swift
struct ScreenshotCapture {
    static let outputDir: String = ProcessInfo.processInfo.environment["SCREENSHOTS_DIR"]
        ?? NSTemporaryDirectory() + "engram-screenshots"

    static func capture(name: String, element: XCUIElement? = nil, app: XCUIApplication) {
        let screenshot = (element ?? app.windows.firstMatch).screenshot()
        let path = "\(outputDir)/\(name).png"
        try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: path))
        ManifestWriter.append(name: name, size: screenshot.size, scale: NSScreen.main?.backingScaleFactor ?? 2)
    }
}

// ManifestWriter — appends to test-manifest.json
struct ManifestWriter {
    static func append(name: String, size: CGSize, scale: CGFloat) {
        // Appends entry to $SCREENSHOTS_DIR/test-manifest.json
    }
}
```

Output `test-manifest.json`:

```json
{
  "screenshots": [
    {
      "name": "home_kpi_cards",
      "screen": "home",
      "test": "testHomeKPICardsRender",
      "timestamp": "2026-03-22T10:00:00Z",
      "size": { "width": 1280, "height": 800 },
      "scale": 2
    }
  ],
  "environment": {
    "os": "15.4",
    "xcode": "16.2",
    "scheme": "EngramUITests",
    "appearance": "light"
  }
}
```

### 4.2 Comparison (Node)

**New file**: `scripts/screenshot-compare.ts`

**Dependencies** (devDependencies):
- `pixelmatch` — pixel-level diff, generates diff image
- `sharp` — PNG read/write, image manipulation
- `ssim.js` — structural similarity index
- `imghash` — perceptual hash (average hash + hamming distance)

**Flow**:

```
1. Read $SCREENSHOTS_DIR/test-manifest.json
2. For each screenshot:
   a. Load actual PNG from $SCREENSHOTS_DIR/{name}.png
   b. Load baseline PNG from baselines/{name}.png
   c. No baseline → status: "new", skip comparison
   d. Size mismatch → status: "size_mismatch", fail
   e. Run pixelmatch → diffCount, generate diff PNG
   f. Run ssim.js → SSIM score (0.0 – 1.0)
   g. Run imghash → pHash hamming distance
   h. All three pass thresholds → status: "passed"
   i. Any fails → status: "failed"
3. Write comparison-report.json
4. Write diff PNGs to $SCREENSHOTS_DIR/diffs/
5. Exit code: 0 if all pass, 1 if any fail
```

**No resize**: If baseline and actual have different dimensions, it's a `size_mismatch` failure. Baselines must be captured at the same resolution as CI.

### 4.3 Thresholds

**Config file**: `screenshot-compare.config.json` (project root)

```json
{
  "ssim_threshold": 0.95,
  "phash_max_distance": 8,
  "pixel_diff_max_percent": 0.5,
  "ignore_regions": {
    "home_recent_sessions": [
      { "x": 0, "y": 0, "w": 200, "h": 30, "reason": "relative timestamp text" }
    ]
  }
}
```

- All three metrics must pass for a screenshot to pass
- `ignore_regions` masks dynamic content (timestamps, animation frames) by zeroing those pixels before comparison
- Per-screenshot overrides possible

### 4.4 Comparison Report

**Output**: `$SCREENSHOTS_DIR/comparison-report.json`

```json
{
  "summary": {
    "total": 38,
    "passed": 35,
    "failed": 2,
    "new": 1,
    "size_mismatch": 0
  },
  "results": [
    {
      "name": "sessions_filter_today",
      "status": "failed",
      "metrics": {
        "ssim": 0.943,
        "phash_distance": 5,
        "pixel_diff_count": 1847,
        "pixel_diff_percent": 0.14
      },
      "paths": {
        "baseline": "baselines/sessions_filter_today.png",
        "actual": "actual/sessions_filter_today.png",
        "diff": "diffs/sessions_filter_today_diff.png"
      },
      "environment": {
        "os": "15.4",
        "xcode": "16.2",
        "appearance": "light"
      },
      "ai_triage": null
    }
  ],
  "thresholds": {
    "ssim_threshold": 0.95,
    "phash_max_distance": 8,
    "pixel_diff_max_percent": 0.5
  }
}
```

The `ai_triage` field is reserved for SP3. Current value is always `null`.

### 4.5 Baseline Management

**Storage**: `macos/EngramUITests/baselines/` tracked by Git LFS.

```gitattributes
# .gitattributes
macos/EngramUITests/baselines/*.png filter=lfs diff=lfs merge=lfs -text
```

**CLI Commands**:

```bash
# Generate baselines (first time or full refresh)
npm run baselines:generate
# Runs: xcodebuild test ... && copies actual/ → baselines/

# Update specific page baselines after intentional UI change
npm run baselines:update -- home
# Copies only home_*.png from actual/ → baselines/

# Update all baselines
npm run baselines:update
# Copies all actual/ → baselines/

# Compare against current baselines (local dev)
npm run screenshots:compare
```

**First-run flow**: When no baselines exist, `screenshots:compare` treats all screenshots as `"new"` and exits 0 with a warning. Developer then runs `baselines:generate` to establish initial baselines.

**Local cleanup**: `ScreenshotCapture` clears `$SCREENSHOTS_DIR` at the start of each test run (`setUp` of the base test class) to prevent stale screenshots from previous runs accumulating.

---

## Layer 5: CI Pipeline

### 5.1 test.yml — New Job: ui-test-smoke (PR trigger)

```yaml
ui-test-smoke:
  runs-on: macos-15
  if: github.event_name == 'pull_request'
  timeout-minutes: 10
  needs: [typescript, swift-unit]  # Only run if unit tests pass
  env:
    SCREENSHOTS_DIR: ${{ runner.temp }}/screenshots
  steps:
    - uses: actions/checkout@v4
      with:
        lfs: true

    - uses: actions/setup-node@v4
      with:
        node-version: 20
        cache: npm

    - name: Install dependencies
      run: npm ci

    - name: Build TypeScript
      run: npm run build

    - name: Cache SPM packages
      uses: actions/cache@v4
      with:
        path: ~/Library/Developer/Xcode/DerivedData/**/SourcePackages
        key: spm-${{ hashFiles('macos/project.yml') }}

    - name: Install xcodegen
      run: brew install xcodegen

    - name: Generate Xcode project
      run: cd macos && xcodegen generate

    - name: Generate fixture DB
      run: npm run generate:fixtures

    - name: Run UI smoke tests
      run: |
        mkdir -p $SCREENSHOTS_DIR
        xcodebuild test \
          -project macos/Engram.xcodeproj \
          -scheme Engram \
          -only-testing:EngramUITests/SmokeTests \
          -destination 'platform=macOS' \
          -resultBundlePath ${{ runner.temp }}/ui-test-results \
          CODE_SIGN_IDENTITY="-" \
          DEVELOPMENT_TEAM="" \
          SCREENSHOTS_DIR=$SCREENSHOTS_DIR

    - name: Compare screenshots
      if: always()
      run: npx tsx scripts/screenshot-compare.ts

    - name: Upload diff artifacts
      if: failure()
      uses: actions/upload-artifact@v4
      with:
        name: screenshot-diffs
        path: |
          ${{ runner.temp }}/screenshots/diffs/
          ${{ runner.temp }}/screenshots/comparison-report.json
        retention-days: 14

    - name: Comment on PR
      if: failure()
      uses: actions/github-script@v7
      with:
        script: |
          const fs = require('fs');
          const report = JSON.parse(fs.readFileSync(
            `${process.env.SCREENSHOTS_DIR}/comparison-report.json`, 'utf8'
          ));
          const failures = report.results.filter(r => r.status === 'failed');
          let body = `📸 **Screenshot Regression**: ${failures.length} failure(s)\n\n`;
          body += `| Screen | SSIM | Pixel Diff | Status |\n|--------|------|------------|--------|\n`;
          for (const f of failures) {
            body += `| ${f.name} | ${f.metrics.ssim.toFixed(3)} | ${f.metrics.pixel_diff_percent.toFixed(2)}% | ❌ |\n`;
          }
          body += `\nView diff images in [artifacts](${context.serverUrl}/${context.repo.owner}/${context.repo.repo}/actions/runs/${context.runId}).`;
          await github.rest.issues.createComment({
            owner: context.repo.owner,
            repo: context.repo.repo,
            issue_number: context.issue.number,
            body
          });
```

**Code signing note**: `CODE_SIGN_IDENTITY="-"` enables ad-hoc signing, which is sufficient for UI test runners on GitHub Actions macOS runners. If this fails on certain runner images, fall back to `CODE_SIGNING_ALLOWED=NO` — but UI tests may require a signed test runner to launch. Verify during initial CI setup.

### 5.2 Main Branch Full Suite (push to main)

```yaml
ui-test-full:
  runs-on: macos-15
  if: github.ref == 'refs/heads/main'
  timeout-minutes: 20
  needs: [typescript, swift-unit]
  env:
    SCREENSHOTS_DIR: ${{ runner.temp }}/screenshots
  steps:
    # Same setup as smoke (checkout with LFS, node, npm ci, build, SPM cache, xcodegen, fixtures)
    - name: Run full UI test suite
      run: |
        mkdir -p $SCREENSHOTS_DIR
        xcodebuild test \
          -project macos/Engram.xcodeproj \
          -scheme Engram \
          -destination 'platform=macOS' \
          -resultBundlePath ${{ runner.temp }}/ui-test-results \
          CODE_SIGN_IDENTITY="-" \
          DEVELOPMENT_TEAM="" \
          SCREENSHOTS_DIR=$SCREENSHOTS_DIR

    - name: Compare screenshots
      if: always()
      run: npx tsx scripts/screenshot-compare.ts

    - name: Upload artifacts
      if: failure()
      uses: actions/upload-artifact@v4
      with:
        name: screenshot-diffs-full
        path: |
          ${{ runner.temp }}/screenshots/diffs/
          ${{ runner.temp }}/screenshots/comparison-report.json
        retention-days: 30
```

### 5.3 Estimated CI Times

| Job | Trigger | Tests | Est. Time | Runner Cost |
|-----|---------|-------|-----------|-------------|
| ui-test-smoke | PR | 15 | ~4-5 min | ~$0.50 |
| ui-test-full | main push | 59 | ~12-15 min | ~$1.50 |

### 5.4 xcodegen project.yml Addition

```yaml
# Target definition
EngramUITests:
  type: bundle.ui-testing
  platform: macOS
  sources:
    - path: EngramUITests
      excludes:
        - "baselines/**"
  dependencies:
    - target: Engram
  settings:
    TEST_TARGET_NAME: Engram
    SCREENSHOTS_DIR: $(SCREENSHOTS_DIR)
```

**Scheme configuration**: UI tests run under the main `Engram` scheme (not a separate `EngramUITests` scheme). Add the UI test target to the existing Engram scheme's test action:

```yaml
# In the existing Engram scheme definition
schemes:
  Engram:
    build:
      targets:
        Engram: all
    test:
      targets:
        - EngramTests
        - EngramUITests
      environmentVariables:
        - variable: SCREENSHOTS_DIR
          value: $(SCREENSHOTS_DIR)
          isEnabled: true
    run:
      config: Debug
```

This ensures `xcodebuild test -scheme Engram -only-testing:EngramUITests/SmokeTests` works correctly.

**Note on SCREENSHOTS_DIR**: Build settings passed to xcodebuild are NOT automatically available as runtime environment variables. The `environmentVariables` in the scheme's test action bridges this gap — `ProcessInfo.processInfo.environment["SCREENSHOTS_DIR"]` in `ScreenshotCapture.swift` reads from the scheme's test environment, which references the build setting `$(SCREENSHOTS_DIR)`, which is set by the CI `SCREENSHOTS_DIR=...` xcodebuild argument.

### 5.5 Permissions

```yaml
permissions:
  contents: read
  pull-requests: write  # For PR comment on failure
```

---

## Layer 6: npm Script Additions

### 6.1 package.json Scripts

```json
{
  "scripts": {
    "screenshots:compare": "tsx scripts/screenshot-compare.ts",
    "baselines:generate": "tsx scripts/baselines-generate.ts",
    "baselines:update": "tsx scripts/baselines-update.ts"
  }
}
```

### 6.2 New devDependencies

```json
{
  "pixelmatch": "^6.0.0",
  "sharp": "^0.33.0",
  "ssim.js": "^3.5.0",
  "imghash": "^1.1.0"
}
```

**Notes**:
- `sharp` handles all PNG I/O — read images, extract raw pixel buffers (`.raw().toBuffer()`), write diff PNGs. No need for separate `pngjs`.
- `imghash` latest published is 1.1.x (no 2.x exists).
- `sharp` uses native `libvips` bindings. On GitHub Actions `macos-15` runners, prebuilt binaries are available for arm64. If installation fails, add `brew install vips` as a CI prerequisite step.

---

## File Inventory

### New Files (Swift)

**UI Test Target** (`macos/EngramUITests/`):

| File | Purpose |
|------|---------|
| `Screens/*.swift` (17) | Page Objects: Home, Sessions, SessionDetail, Search, Settings, Activity, Timeline, SourcePulse, Projects, Observability, Repos, Agents, Memory, Hooks, Skills, Popover, Sidebar |
| `Helpers/TestLaunchConfig.swift` | Launch argument configuration |
| `Helpers/ScreenshotCapture.swift` | Screenshot utility + manifest writer |
| `Helpers/WaitUtils.swift` | Explicit waits for async data loading |
| `Tests/SmokeTests/*.swift` (7) | HomeSmokeTests, SessionsSmokeTests, SessionDetailSmokeTests, SearchSmokeTests, NavigationSmokeTests, PopoverSmokeTests, ActivitySmokeTests |
| `Tests/FullTests/*.swift` (17) | HomeTests, SessionsTests, SessionDetailTests, SearchTests, SettingsTests, ActivityTests, TimelineTests, SourcePulseTests, ProjectsTests, ObservabilityTests, ReposTests, AgentsTests, MemoryTests, HooksTests, SkillsTests, NavigationTests, DarkModeTests |

**App Target** (`macos/Engram/Core/`, `#if DEBUG`):

| File | Purpose |
|------|---------|
| `MockDaemonFixtures.swift` | Hardcoded JSON responses for DaemonClient test mode |

### New Files (TypeScript — 3 files)

| File | Purpose |
|------|---------|
| `scripts/screenshot-compare.ts` | Comparison pipeline (pixelmatch + ssim.js + imghash) |
| `scripts/baselines-generate.ts` | First-time baseline generation |
| `scripts/baselines-update.ts` | Selective baseline update |

### Modified Files

| File | Change |
|------|--------|
| `macos/project.yml` | Add EngramUITests target + update Engram scheme with UI test target |
| `.github/workflows/test.yml` | Add ui-test-smoke and ui-test-full jobs |
| `.gitattributes` | Add LFS tracking for baseline PNGs |
| `package.json` | Add scripts + devDependencies (pixelmatch, sharp, ssim.js, imghash) |
| `scripts/generate-test-fixtures.ts` | Seed git_repos, logs, traces, metrics |
| `macos/Engram/Core/DaemonClient.swift` | Add `testMode` flag + `#if DEBUG` mock response path |
| `macos/Engram/Core/AppEnvironment.swift` | Add `popoverStandalone`, `windowSize` parsed from CLI args |
| `macos/Engram/AppDelegate.swift` | Parse `--mock-daemon`, `--appearance`, `--popover-standalone`; create standalone popover window |
| `macos/Engram/Core/MenuBarController.swift` | Respect `windowSize` from AppEnvironment in `openWindow()` |
| ~53 view files | Add `.accessibilityIdentifier()` modifiers |

### Baseline Files (Git LFS)

| Directory | Contents |
|-----------|----------|
| `macos/EngramUITests/baselines/` | 39 baseline PNGs (~2-5 MB total) |

---

## Success Criteria

1. **59 XCUITest cases pass** on macOS 15 with fixture DB
2. **39 baseline screenshots** captured and committed via Git LFS
3. **Screenshot comparison pipeline** detects intentional changes (SSIM < 0.95 triggers failure)
4. **PR smoke tests** complete in < 5 minutes
5. **Full suite** completes in < 15 minutes on main branch
6. **Popover standalone** renders identically to real popover content
7. **comparison-report.json** produced with SP3-ready `ai_triage` field
8. **Zero false positives** from dynamic content (timestamps masked via ignore_regions + fixed-date)
