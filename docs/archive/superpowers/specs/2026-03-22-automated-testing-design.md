# Engram Automated Testing System Design

**Date**: 2026-03-22
**Status**: Draft
**Scope**: TypeScript + macOS SwiftUI app, full test pyramid + AI-assisted diagnostics

## Problem

Engram's TypeScript layer has 427 tests (vitest), but the macOS SwiftUI app (86 files, 12K+ LOC) has zero tests. There are no UI automation tests, no screenshot regression testing, no E2E tests spanning daemon↔app, and no CI/CD pipeline. When a release is cut, there is no automated way to verify that all features work correctly.

## Goals

1. Swift unit tests for core logic (DatabaseManager, DaemonClient, MessageParser)
2. XCUITest UI automation covering every page and major interaction
3. Screenshot comparison with perceptual diffing
4. AI-powered triage: distinguish "expected change" from "bug", auto-fix (phased)
5. E2E tests spanning daemon → indexing → UI display
6. CI/CD pipeline with release gating
7. TypeScript test coverage measurement and gap filling

## Non-Goals

- Cross-platform testing (Engram is macOS-only)
- Load/stress testing (local app, not a service)
- Accessibility audit automation (future)

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    Test Pyramid                         │
│                                                         │
│                    ┌───────┐                             │
│                    │  E2E  │  5-10 tests                │
│                    │ tests │  daemon → index → UI       │
│                   ┌┴───────┴┐                            │
│                   │   UI    │  50+ XCUITest cases        │
│                   │  tests  │  screenshot comparison     │
│                  ┌┴─────────┴┐                           │
│                  │   Unit    │  Swift: 100+ tests        │
│                  │   tests   │  TS: 427+ tests (exist)  │
│                 ┌┴───────────┴┐                          │
│                 │  Fixtures    │  Test data, mock daemon │
│                 └─────────────┘                          │
└─────────────────────────────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────────────────────────┐
│              AI Triage Pipeline                          │
│                                                         │
│  Screenshot diff → Perceptual analysis → AI classify    │
│                                                         │
│  Phase A: Generate diagnostic report + fix suggestions  │
│  Phase B: Auto-create fix PR                            │
│  Phase C: Auto-fix → re-test → auto-merge               │
└─────────────────────────────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────────────────────────┐
│              CI/CD Pipeline                              │
│                                                         │
│  PR: TS unit + Swift unit + UI smoke (5 min)            │
│  Main: Full suite (15 min)                              │
│  Release: Full suite + screenshot diff + report         │
└─────────────────────────────────────────────────────────┘
```

---

## Layer 1: Swift Unit Tests

### Setup

Add test targets to `macos/project.yml`:

```yaml
targets:
  EngramTests:
    type: bundle.unit-test
    platform: macOS
    deploymentTarget: "14.0"
    sources:
      - path: EngramTests
    dependencies:
      - target: Engram
    settings:
      PRODUCT_BUNDLE_IDENTIFIER: com.engram.app.tests

  EngramUITests:
    type: bundle.ui-testing
    platform: macOS
    deploymentTarget: "14.0"
    sources:
      - path: EngramUITests
    dependencies:
      - target: Engram
    settings:
      PRODUCT_BUNDLE_IDENTIFIER: com.engram.app.uitests
```

### Test Files

**Core logic (priority order)**:

| File | Tests | What to Test |
|------|-------|-------------|
| `DatabaseManagerTests.swift` | 20+ | Session queries, FTS search, CJK handling, tier filtering, favorites, tags |
| `DaemonClientTests.swift` | 10+ | HTTP calls, error handling, response parsing, timeout |
| `MessageParserTests.swift` | 15+ | JSON line parsing, malformed input, edge cases |
| `MessageTypeClassifierTests.swift` | 10+ | Message type detection, tool classification |
| `IndexerProcessTests.swift` | 10+ | Process lifecycle, status parsing, event handling |
| `SessionModelTests.swift` | 10+ | Model initialization, computed properties, sorting |
| `StreamingJSONLReaderTests.swift` | 10+ | Streaming parse, partial lines, encoding |
| `SourceColorsTests.swift` | 5+ | Color mapping for all 15 sources |
| `ThemeTests.swift` | 5+ | Theme values, dark/light consistency |

**Testing approach**:
- DatabaseManager: Use in-memory SQLite via GRDB, seed with fixture data
- DaemonClient: Mock HTTP via URLProtocol
- MessageParser: Real JSONL fixture data (reuse from TS test fixtures)
- IndexerProcess: Mock process output

**Target**: 100+ Swift unit tests, 80%+ coverage on Core/ and Models/

---

## Layer 2: XCUITest UI Automation

### Test Organization

One test file per page/feature area:

```
macos/EngramUITests/
  EngramUITestCase.swift        # Base class: launch, helpers, screenshot
  Pages/
    HomePageTests.swift          # Home dashboard widgets, KPIs
    SessionsPageTests.swift      # Session list, filtering, sorting, tier picker
    SessionDetailTests.swift     # Transcript view, message display, metadata
    SearchPageTests.swift        # Search input, results, FTS/Viking toggle
    ActivityPageTests.swift      # Activity charts, date range picker
    ProjectsPageTests.swift      # Project list, project detail
    TimelinePageTests.swift      # Timeline view, navigation
    AgentsPageTests.swift        # Agent session listing
    MemoryPageTests.swift        # Memory entries display
    HooksPageTests.swift         # Hooks listing
    SkillsPageTests.swift        # Skills listing
    SourcePulsePageTests.swift   # Source status, health indicators
    SettingsTests.swift          # All settings sections, toggles
  Components/
    PopoverTests.swift           # Menu bar popover (see Popover Testing caveat below)
    SidebarTests.swift           # Navigation, page switching
    FilterPillTests.swift        # Filter interaction, clear
    SessionCardTests.swift       # Card display, tap to detail
  Workflows/
    SearchWorkflowTests.swift    # Type query → see results → tap result → see detail
    SessionBrowseTests.swift     # Navigate sessions → filter → sort → detail
    SettingsWorkflowTests.swift  # Change setting → verify effect
```

### Base Test Case

```swift
class EngramUITestCase: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // Launch with test fixtures (isolated DB)
        app.launchArguments = ["--test-mode", "--fixture-db", fixtureDBPath()]
        app.launch()
    }

    // Screenshot capture with naming convention
    func takeScreenshot(name: String) -> XCUIScreenshot {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        return screenshot
    }

    // Navigate to a specific page
    func navigateTo(page: String) {
        let sidebar = app.outlines.firstMatch
        sidebar.staticTexts[page].click()
        // Wait for page to load
        XCTAssertTrue(app.staticTexts[page].waitForExistence(timeout: 5))
    }
}
```

### Prerequisite Refactoring for Testability

The current Swift codebase has tight coupling in several areas that must be decoupled before `--test-mode` can work. This is a prerequisite, not optional.

**Modules requiring refactoring**:

| Module | Current State | Required Change |
|--------|--------------|-----------------|
| `DatabaseManager` | Hardcoded path `~/.engram/index.sqlite` | Accept path via init parameter; test mode passes fixture path |
| `DaemonClient` | Hardcoded `localhost:3636` | Accept base URL via init; test mode uses mock or fixture server |
| `IndexerProcess` | Auto-launches daemon on init | Add `autoStart: Bool` parameter; test mode sets `false` |
| `MCPServer` | Tightly coupled to IndexerProcess | Decouple via protocol; test mode uses stub |
| `EngramApp` (entry point) | Creates all dependencies inline | Extract `AppEnvironment` struct holding all config (db path, daemon URL, autoStart, networkEnabled) |

**Refactoring approach**: Introduce an `AppEnvironment` struct (similar to SwiftUI's `@Environment`):

```swift
struct AppEnvironment {
    let dbPath: String
    let daemonURL: URL
    let autoStartDaemon: Bool
    let networkEnabled: Bool  // controls Viking, AI calls
    let fixedDate: Date?      // nil = use real time; non-nil = deterministic

    static let production = AppEnvironment(...)
    static func test(fixturePath: String) -> AppEnvironment { ... }
}
```

`EngramApp` reads `CommandLine.arguments` at launch, builds the appropriate `AppEnvironment`, and injects it via `.environment()`. This is a one-time refactoring that pays for itself across all test layers.

**Estimated scope**: ~8 files modified, no behavioral changes to production code. Pure dependency injection.

### Test Mode

The app reads `--test-mode` from launch arguments and constructs `AppEnvironment.test(fixturePath:)`:
1. Uses a fixture SQLite database (pre-seeded with known sessions)
2. Disables daemon auto-start (no real indexing during tests)
3. Disables network calls (Viking, AI)
4. Uses deterministic data (fixed dates, known session counts)

**Fixture DB**: Pre-built SQLite with ~20 sessions across 5 sources, known metadata. Stored at `macos/EngramTests/Fixtures/test-index.sqlite`.

### Test Case Coverage Target: 50+ UI Tests

**Per-page breakdown**:

| Page | Test Count | Key Scenarios |
|------|-----------|---------------|
| Home | 4 | Dashboard loads, KPI values correct, recent sessions show, sparklines render |
| Sessions | 6 | List loads, filter by source, filter by tier, sort by date, search within, pagination |
| Session Detail | 5 | Transcript loads, messages display, tool calls shown, metadata correct, copy works |
| Search | 5 | Empty state, text search returns results, click result navigates, no results state, CJK search |
| Activity | 3 | Chart renders, date range change updates, source breakdown correct |
| Projects | 3 | Project list loads, project detail shows sessions, project alias displayed |
| Timeline | 3 | Timeline renders, navigation between dates, session markers correct |
| Agents | 2 | Agent sessions listed, filter works |
| Memory | 2 | Memory entries display, search works |
| Hooks | 2 | Hooks listed, detail view works |
| Skills | 2 | Skills listed, detail view works |
| SourcePulse | 3 | Sources status shown, health indicators correct, stale source highlighted |
| Settings | 4 | All sections accessible, toggles work, text fields save, reset works |
| Popover | 3 | Opens from menu bar, shows summary, quick actions work (see caveat) |
| Sidebar | 2 | All pages accessible, selection highlight correct |
| Workflows | 3 | Search→detail, browse→filter→detail, settings change |
| **Total** | **52** | |

### Popover Testing Caveat (macOS XCUITest Limitation)

macOS XCUITest has limited support for menu bar status items and NSPopover. Unlike iOS, the menu bar is owned by the system, and XCUITest cannot reliably click status bar items or find accessibility elements inside popovers.

**Fallback strategy**:
1. **First attempt**: Use `XCUIApplication.statusItems` API (available macOS 13+). If the popover's accessibility tree is visible to XCUITest, use standard XCUITest assertions.
2. **Fallback**: If status item interaction is unreliable, use `AXUIElement` API (Accessibility framework) to programmatically click the status item and query popover contents. Wrap in a `PopoverTestHelper` utility.
3. **Last resort**: For CI environments where popover tests are flaky, tag popover tests with `@available` and allow skipping via `SKIP_POPOVER_TESTS=1` env var. Popover testing remains mandatory for local development and release pipelines.

This risk is acknowledged upfront. The implementation plan should schedule popover tests last in the UI test phase, after all main window tests are stable.

---

## Layer 3: Screenshot Comparison

### Baseline Management

```
tests/screenshots/
  baselines/
    macOS-15.4/         # Per-OS minor version (major.minor, ignore patch)
      home-dashboard.png
      sessions-list.png
      sessions-filtered.png
      session-detail-transcript.png
      search-results.png
      search-empty.png
      activity-chart.png
      settings-general.png
      popover-summary.png
      ...
  diffs/                # Generated on test run
    session-detail-transcript-diff.png
  reports/
    2026-03-22T14-30-00-report.json
```

### Comparison Algorithm

**Two-phase comparison**:

1. **Perceptual hash (pHash)** — fast, coarse check. If hamming distance < 5, pass.
2. **SSIM (Structural Similarity)** — if pHash fails, compute SSIM. Threshold: 0.95.

**Implementation**: Use a Swift helper that wraps `vImage` (Accelerate framework) for SSIM. No external dependencies.

```swift
struct ScreenshotComparator {
    static func compare(baseline: CGImage, current: CGImage) -> ComparisonResult {
        let phashDistance = perceptualHashDistance(baseline, current)
        if phashDistance < 5 { return .match }

        let ssim = computeSSIM(baseline, current)
        if ssim > 0.95 { return .match }

        let diffImage = generateDiffImage(baseline, current)
        return .mismatch(ssim: ssim, phashDistance: phashDistance, diff: diffImage)
    }
}
```

### Baseline Update Flow

```
Test fails (screenshot mismatch)
    │
    ▼
Generate diff image + comparison report
    │
    ▼
AI Triage (Layer 4) classifies:
    ├── "Expected change" → update baseline, log reason
    └── "Bug" → generate diagnostic report
```

**Manual override**: `UPDATE_SCREENSHOTS=1 xcodebuild test ...` to force-update all baselines.

**OS version granularity**: Baselines are keyed by **major.minor** version (e.g., `macOS-15.4/`), ignoring patch. Minor version updates (15.3 → 15.4) can change font hinting, system control rendering, and spacing, warranting new baselines. Patch updates (15.4.0 → 15.4.1) rarely affect rendering and are absorbed by the SSIM 0.95 threshold.

**Auto-rebuild on OS version change**: The CI pipeline detects the current macOS version (`sw_vers -productVersion`, truncated to major.minor) and checks if a matching `baselines/macOS-{version}/` directory exists. If not:
1. Run all UI tests with `UPDATE_SCREENSHOTS=1` to capture new baselines.
2. Commit new baselines to a PR branch `chore/update-baselines-macOS-{version}`.
3. Skip screenshot comparison for this run (first run on new OS is always a baseline capture).
4. Subsequent runs on this OS version use the new baselines normally.

This prevents all screenshot tests from failing en masse when GitHub upgrades their macOS runner image.

---

## Layer 4: AI Triage Pipeline

### Phase A: Diagnostic Reports (Initial)

When a screenshot test fails:

1. Capture: baseline image, current image, diff image
2. Capture: recent git changes (files changed, commit messages)
3. Capture: relevant logs/traces from test run (if observability system is in place)
4. Send to AI (Claude API) with prompt:

```
You are analyzing a UI test failure for Engram, a macOS app.

Baseline screenshot: [image]
Current screenshot: [image]
Diff highlight: [image]
SSIM score: 0.82

Recent changes:
- [git diff summary]

Test name: SessionsPageTests.testFilterBySource
Expected: Sessions list filtered to show only Claude Code sessions
Actual: Screenshot mismatch

Classify this as:
1. EXPECTED_CHANGE — intentional UI modification (describe what changed and why it's expected)
2. BUG — unintended regression (describe the bug and suggest root cause)
3. FLAKY — non-deterministic difference (e.g., timing, animation state)

Then provide:
- Root cause analysis
- Suggested fix (if bug)
- Affected components
```

**Output**: JSON diagnostic report saved to `tests/screenshots/reports/`:

```json
{
  "testName": "SessionsPageTests.testFilterBySource",
  "timestamp": "2026-03-22T14:30:00Z",
  "classification": "BUG",
  "confidence": 0.92,
  "analysis": "Filter pill selection state is not being applied...",
  "suggestedFix": "Check FilterPillView.swift binding...",
  "affectedFiles": ["macos/Engram/Components/FilterPills.swift"],
  "ssim": 0.82,
  "baselineImage": "sessions-filtered.png",
  "diffImage": "sessions-filtered-diff.png"
}
```

### AI Triage Cost & Reliability

**API key**: Stored as GitHub Actions secret `ANTHROPIC_API_KEY`. Same key used in development.

**Cost per triage call**: ~3 images (baseline + current + diff) × ~1000 tokens each + prompt ~500 tokens + response ~500 tokens ≈ **~5K tokens per failure**. At $3/MTok (Sonnet), each failure costs ~$0.015.

**Budget cap**: Max **10 triage calls per CI run**. If more than 10 screenshot tests fail, remaining failures are reported without AI analysis (raw diff images only). This caps AI cost at ~$0.15 per release pipeline run.

**API unavailability**: If Claude API is unreachable (timeout 30s, 1 retry), the triage step is **skipped, not failed**. Screenshot comparison results are still saved as artifacts. AI triage is advisory — it must never block a release. The pipeline step uses `continue-on-error: true`.

### Phase B: Auto-Fix PR (Future)

When classification is BUG with confidence > 0.85:
1. AI generates fix based on analysis
2. Creates branch `fix/test-{testName}-{date}`
3. Applies fix, runs tests locally
4. If tests pass, creates PR with diagnostic report attached
5. Human reviews and merges

### Phase C: Full Automation (Future)

Same as Phase B, but:
- If all tests pass after fix, auto-merge to main
- If tests still fail, escalate to human with full context
- Rate-limited: max 3 auto-fixes per day

---

## Layer 5: E2E Full-Chain Tests

### Setup

E2E tests launch a real daemon process with fixture data and verify the full chain:

```swift
class E2ETestCase: XCTestCase {
    var daemonProcess: Process!
    var app: XCUIApplication!

    override func setUpWithError() throws {
        // 1. Prepare fixture session files in temp dir
        let fixtureDir = prepareFixtures()

        // 2. Launch daemon with fixture config
        daemonProcess = Process()
        daemonProcess.executableURL = URL(fileURLWithPath: nodePath)
        daemonProcess.arguments = [daemonJSPath, "--config", fixtureConfigPath]
        daemonProcess.environment = [
            "ENGRAM_DATA_DIR": tempDataDir,
            "ENGRAM_SOURCES": fixtureDir
        ]
        try daemonProcess.run()

        // 3. Wait for daemon ready (health check with timeout)
        try waitForDaemonReady(timeout: 30, pollInterval: 0.5)

        // 4. Launch app pointing to same data dir
        app = XCUIApplication()
        app.launchArguments = ["--data-dir", tempDataDir]
        app.launch()
    }

    override func tearDownWithError() throws {
        daemonProcess.terminate()
        cleanupTempDir()
    }
}
```

**Daemon health check details**:
- `waitForDaemonReady(timeout:pollInterval:)` polls `GET http://localhost:{port}/health` every `pollInterval` seconds.
- Total timeout: **30 seconds** (local dev typically ready in 2-3s; CI may take 10-15s due to slower disk).
- If timeout reached: fail the test with diagnostic message including daemon stderr output.
- **No retry on failure** — if daemon can't start, the test fails hard. Daemon startup issues are real bugs.
- Node binary resolution: use `ENGRAM_NODE_PATH` env var if set (CI sets this), otherwise `which node` (local dev).
- Daemon JS path: `dist/daemon.js`, built from `npm run build` output. **E2E tests require the daemon build artifact.** CI must run `npm ci && npm run build` in the same job before E2E tests execute. In the release pipeline (`release.yml`), this is handled by the serial step order within `full-test-suite` job — `npm run build` runs before `xcodebuild test`, and the `dist/` directory is available to the E2E test process.

### E2E Test Cases (5-10)

| Test | Flow | Verifies |
|------|------|----------|
| `testIndexingToDisplay` | Daemon indexes fixtures → App shows sessions | Session count, source icons, metadata |
| `testSearchFullChain` | Index → Search query → Results display | Search accuracy, result ranking, detail navigation |
| `testSessionDetail` | Index → Navigate to session → View transcript | Message count, tool calls, timestamps |
| `testSourcePulse` | Index → Check SourcePulse page | Source status matches indexed data |
| `testActivityData` | Index → Check Activity page | Charts reflect indexed session dates |
| `testProjectGrouping` | Index sessions with project paths → Projects page | Project grouping, session count per project |
| `testDaemonRestart` | Kill daemon → App shows error → Restart → Recovery | Error state UI, auto-recovery |
| `testIncrementalIndex` | Index → Add new fixture file → Re-index → Verify | New session appears in UI |

---

## Layer 6: CI/CD Pipeline

### GitHub Actions Configuration

```yaml
# .github/workflows/test.yml
name: Tests
on:
  pull_request:
    branches: [main]
  push:
    branches: [main]

jobs:
  typescript-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: '22' }
      - run: npm ci
      - run: npm run build
      - run: npm test
      - run: npm run test:coverage
      - uses: actions/upload-artifact@v4
        with:
          name: ts-coverage
          path: coverage/

  swift-unit-tests:
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: '22' }
      # Validate fixture DB schema version matches current code
      - run: npm ci && node scripts/check-fixture-schema.mjs
      - run: cd macos && xcodegen generate
      - run: |
          xcodebuild test \
            -project macos/Engram.xcodeproj \
            -scheme Engram \
            -destination 'platform=macOS' \
            -resultBundlePath TestResults.xcresult
      - uses: actions/upload-artifact@v4
        with:
          name: swift-test-results
          path: TestResults.xcresult

  ui-smoke-tests:
    runs-on: macos-15
    needs: [swift-unit-tests]
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: '22' }
      - run: npm ci && npm run build
      - run: cd macos && xcodegen generate
      - run: |
          xcodebuild test \
            -project macos/Engram.xcodeproj \
            -scheme Engram -only-testing:EngramUITests \
            -destination 'platform=macOS' \
            -only-testing:EngramUITests/SmokeTests \
            -resultBundlePath UITestResults.xcresult
      - uses: actions/upload-artifact@v4
        with:
          name: ui-test-results
          path: UITestResults.xcresult
```

```yaml
# .github/workflows/release.yml
name: Release Gate
on:
  push:
    tags: ['v*']

jobs:
  full-test-suite:
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: '22' }
      - run: npm ci && npm run build
      - run: npm test
      - run: cd macos && xcodegen generate
      # Swift unit tests
      - run: |
          xcodebuild test \
            -project macos/Engram.xcodeproj \
            -scheme Engram \
            -destination 'platform=macOS'
      # Full UI test suite (all 50+ tests, parallel execution)
      - run: |
          xcodebuild test \
            -project macos/Engram.xcodeproj \
            -scheme Engram -only-testing:EngramUITests \
            -destination 'platform=macOS' \
            -parallel-testing-enabled YES \
            -maximum-parallel-testing-workers 4 \
            -resultBundlePath FullUITestResults.xcresult
      # Screenshot comparison
      - run: swift scripts/compare-screenshots.swift
      # AI triage for failures
      - run: node scripts/ai-triage.mjs
      # Upload all results
      - uses: actions/upload-artifact@v4
        with:
          name: release-test-results
          path: |
            FullUITestResults.xcresult
            tests/screenshots/diffs/
            tests/screenshots/reports/
```

### Pipeline Timing & Cost

| Pipeline | Trigger | Tests Run | Target Time | macOS Minutes |
|----------|---------|-----------|-------------|---------------|
| PR | Pull request | TS unit + Swift unit + UI smoke (10 tests) | < 5 min | ~8 min |
| Main | Push to main | All unit + UI smoke | < 8 min | ~12 min |
| Release | Tag v* | All unit + all UI (52) + E2E (8) + screenshots | < 20 min | ~25 min |

**Parallel UI testing**: XCUITest defaults to serial execution. At ~15-20s per test, 52 tests serial = ~13-17 min, leaving almost no headroom for E2E + screenshot comparison + AI triage within the 20-min target. The release pipeline enables `-parallel-testing-enabled YES` with 4 workers, reducing UI test time to ~4-5 min. Note: parallel XCUITest launches multiple app instances — test isolation via `AppEnvironment.test()` ensures no shared state conflicts.

**Cost estimate** (GitHub-hosted macOS runners are 10x Linux pricing):
- At ~20 PRs/week: ~160 macOS-min/week (~$16/week at $0.10/min)
- Monthly estimate: ~$65-80/month for CI (dominated by macOS runner time)

**Self-hosted runner option**: The developer has a Mac Mini M2 that can serve as a self-hosted GitHub Actions runner. This eliminates macOS runner costs entirely and provides faster builds (M2 vs GitHub's Intel/M1 runners). Configuration:
- Install `actions-runner` on Mac Mini
- Label: `self-hosted, macOS, ARM64`
- Workflows use `runs-on: [self-hosted, macOS]` instead of `macos-15`
- Tradeoff: requires Mac Mini to be always-on and network-accessible (already the case per existing `pmset` setup)

**Recommendation**: Start with GitHub-hosted for simplicity, switch to self-hosted if monthly cost exceeds $50 or if CI queue times are unacceptable.

---

## Layer 7: TypeScript Test Enhancement

### Coverage Setup

```bash
npm install -D @vitest/coverage-v8
```

Update `vitest.config.ts`:
```typescript
export default defineConfig({
  test: {
    coverage: {
      provider: 'v8',
      reporter: ['text', 'json', 'html'],
      thresholds: {
        statements: 70,
        branches: 65,
        functions: 70,
        lines: 70,
      },
      include: ['src/**/*.ts'],
      exclude: ['src/**/*.d.ts', 'src/cli/**'],
    },
  },
});
```

### Gap Analysis & New Tests

Priority test additions:

| Area | Current | Gap | New Tests |
|------|---------|-----|-----------|
| Adapters | 13 files | Edge cases: malformed files, empty sessions, encoding | +15 tests |
| Error paths | Minimal | Adapter failures, DB corruption, Viking timeout | +20 tests |
| Config | 1 file | Invalid config, migration, defaults | +10 tests |
| Lifecycle | 0 | Process signals, cleanup, idle timeout | +10 tests |
| Web API | 2 files | All endpoints, error responses, pagination | +15 tests |
| CLI | 0 | New observability CLI commands | +10 tests |
| **Total** | 427 | | **+80 tests → 507+** |

---

## Test Data Strategy

### Fixture Database

Pre-built SQLite database with deterministic test data:

```
20 sessions:
  - 5 Claude Code sessions (various lengths, with/without tools)
  - 3 Cursor sessions
  - 2 Codex sessions
  - 2 Gemini CLI sessions
  - 2 Windsurf sessions
  - 1 each: VSCode, Kimi, Qwen, OpenCode, Cline, iFlow

Each session has:
  - Known title, source, project path
  - 5-50 messages with timestamps
  - Tool calls (for some sessions)
  - Cost data (for some sessions)
  - Tier assignments (skip, lite, normal, premium)

3 projects:
  - "engram" (8 sessions)
  - "my-app" (5 sessions)
  - "dotfiles" (3 sessions)
```

**Generation**: Script at `scripts/generate-test-fixtures.ts` builds the fixture DB from template data. Deterministic (seeded random) so it's reproducible.

### Fixture Maintenance

- Fixture DB stored in repo: `macos/EngramTests/Fixtures/test-index.sqlite`
- Fixture generator embeds current `SCHEMA_VERSION` from `db.ts` into fixture DB metadata
- Version-tracked alongside schema version

**Automated rebuild triggers**:
1. **CI check**: Before Swift tests run, CI compares fixture DB's embedded schema version against current `SCHEMA_VERSION` in `db.ts`. If mismatch → fail fast with message: `"Fixture DB schema version (12) != current (13). Run: npm run generate-fixtures"`
2. **npm script**: `npm run generate-fixtures` runs `scripts/generate-test-fixtures.ts`, writes fixture DB, and copies to `macos/EngramTests/Fixtures/`
3. **Pre-commit hook** (optional): If `src/core/db.ts` is staged and fixture DB is not, emit a warning (not blocking)

---

## File Changes Summary

**New directories**:
- `macos/EngramTests/` — Swift unit test files
- `macos/EngramUITests/` — XCUITest UI automation files
- `macos/EngramTests/Fixtures/` — Test fixture database
- `tests/screenshots/baselines/` — Screenshot baselines (**tracked via Git LFS**, see below)
- `tests/screenshots/diffs/` — Generated diff images (gitignored)
- `tests/screenshots/reports/` — AI triage reports
- `.github/workflows/` — CI/CD pipeline configs
- `scripts/` — Test helper scripts

**New files** (key ones):
- `macos/EngramTests/*.swift` — 9+ unit test files
- `macos/EngramUITests/*.swift` — 15+ UI test files
- `macos/EngramUITests/EngramUITestCase.swift` — Base test case
- `.github/workflows/test.yml` — PR/main CI pipeline
- `.github/workflows/release.yml` — Release gate pipeline
- `scripts/generate-test-fixtures.ts` — Fixture DB generator
- `scripts/compare-screenshots.swift` — Screenshot comparison tool
- `scripts/ai-triage.mjs` — AI diagnostic report generator
- `scripts/check-fixture-schema.mjs` — CI fixture DB schema version validator
- `.gitattributes` — Git LFS tracking for screenshot baselines

**Git LFS for screenshot baselines**: 52 screenshots × ~200-500KB = ~10-25MB per OS version. Each OS version upgrade adds a new set. To prevent repository bloat:
- Track `tests/screenshots/baselines/**/*.png` with Git LFS
- Add `.gitattributes`: `tests/screenshots/baselines/**/*.png filter=lfs diff=lfs merge=lfs -text`
- CI uses `actions/checkout@v4` with `lfs: true` to fetch baselines
- Estimated LFS storage: ~50-100MB over 2-3 OS versions (well within free tier of most Git hosting)

**Modified files**:
- `macos/project.yml` — Add EngramTests + EngramUITests targets
- `macos/Engram/` — Add `--test-mode` launch argument handling
- `vitest.config.ts` — Add coverage configuration
- `package.json` — Add @vitest/coverage-v8 dependency, new scripts

## Test Maintenance Strategy

With 600+ tests across TS and Swift, ongoing maintenance is critical to prevent test rot.

**Rules**:
1. **PR rule**: Any PR that modifies a SwiftUI view must update or add the corresponding UI test. CI enforces this by checking if modified view files have matching test file changes (advisory warning, not blocking — some view changes don't affect test behavior).
2. **Screenshot baseline updates**: When a PR intentionally changes UI appearance, the author runs `UPDATE_SCREENSHOTS=1` locally and commits updated baselines in the same PR.
3. **Flaky test policy**: If a test fails intermittently (>2 times in 30 days without code changes), it is either fixed or quarantined (moved to a `Quarantine/` directory, excluded from CI, tracked in an issue). Quarantined tests must be resolved within 2 weeks or deleted.
4. **Fixture DB versioning**: Fixture DB includes a `schema_version` field. If `db.ts` migration version changes and fixture version doesn't match, CI fails with a clear message: "Fixture DB is stale — run `npm run generate-fixtures` to rebuild."
5. **Test ownership**: No explicit per-person ownership. Tests are maintained by whoever changes the corresponding production code.

---

## Implementation Order

**Cross-dependency with Observability spec**: Steps 8 and 9 below depend on the observability system (Layers 1-2 of the observability spec) being in place. E2E tests benefit from structured daemon logs for failure diagnosis. AI triage uses logs/traces in its diagnostic context.

```
Phase 1 (parallel tracks):
  Observability L1-L2          Testing Steps 1-6
  (logger + tracer + schema)   (refactor, unit tests, UI tests, screenshots)
  ┌──────────────────────┐     ┌──────────────────────────────────────┐
  │ L1: Logger + schema  │     │ 1. AppEnvironment refactoring       │
  │ L2: Tracer + spans   │     │ 2. Swift unit tests (100+)          │
  │                      │     │ 3. TS coverage setup (+80 tests)    │
  └──────────┬───────────┘     │ 4. XCUITest infrastructure          │
             │                 │ 5. UI test cases (52 tests)         │
             │                 │ 6. Screenshot comparison             │
             │                 │ 7. CI/CD pipeline (overlap w/ 4-6)  │
             │                 └──────────────┬───────────────────────┘
             │                                │
             ▼                                ▼
Phase 2 (sequential, requires both Phase 1 tracks):
  ┌───────────────────────────────────────────────────┐
  │ 8. E2E tests (daemon logs → UI verification)     │
  │ 9. AI triage (uses logs/traces for diagnostics)   │
  └───────────────────────────────────────────────────┘
```

1. **Prerequisite refactoring** (AppEnvironment, dependency injection for testability — ~8 files)
2. **Swift unit test infrastructure** (project.yml, base classes, first 20 tests)
3. **TypeScript coverage** (install coverage tool, measure gaps, add tests)
4. **XCUITest infrastructure** (base class, test mode, fixture DB generator)
5. **UI test cases** (main window pages first, popover last — 52 tests)
6. **Screenshot comparison** (baseline capture, SSIM comparator, OS version detection)
7. **CI/CD pipeline** (PR pipeline first, then release gate) — can partially overlap with 4-6
8. **E2E tests** (daemon + app full chain) — depends on Observability L1-L2
9. **AI triage** (Phase A: diagnostic reports) — depends on Observability L1-L2

## Success Criteria

- 100+ Swift unit tests passing
- 52+ XCUITest cases covering all pages
- 507+ TypeScript tests with 70%+ coverage
- 8+ E2E tests covering critical paths
- CI pipeline < 5 min for PRs
- Release pipeline < 20 min with full suite
- Screenshot baselines for all pages
- AI diagnostic reports for test failures
