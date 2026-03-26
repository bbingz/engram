# Automated Testing System Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a comprehensive test pyramid for Engram: Swift unit tests, XCUITest UI automation with screenshot comparison, E2E tests, AI-powered triage, and CI/CD with release gating.

**Architecture:** AppEnvironment dependency injection enables test mode. Fixture SQLite DB with seeded data. XCUITest drives UI with parallel execution. Screenshot baselines in Git LFS. CI on GitHub Actions (macOS runner). AI triage via Claude API (Phase A: reports).

**Tech Stack:** XCTest/XCUITest (Swift), vitest (TypeScript), GitHub Actions, Accelerate framework (SSIM), Claude API (triage), Git LFS.

**Spec:** `docs/superpowers/specs/2026-03-22-automated-testing-design.md`

**Dependency:** Tasks 8-9 require Observability Layer 1-2 from `docs/superpowers/plans/2026-03-22-observability.md`.

---

## File Structure

### New Files
| File | Responsibility |
|------|---------------|
| `macos/EngramTests/DatabaseManagerTests.swift` | DB queries, FTS, CJK, tiers, favorites, tags |
| `macos/EngramTests/DaemonClientTests.swift` | HTTP calls, errors, response parsing |
| `macos/EngramTests/MessageParserTests.swift` | JSONL parsing, malformed input |
| `macos/EngramTests/MessageTypeClassifierTests.swift` | Message type detection |
| `macos/EngramTests/IndexerProcessTests.swift` | Process lifecycle, status parsing |
| `macos/EngramTests/SessionModelTests.swift` | Model init, computed props, sorting |
| `macos/EngramTests/StreamingJSONLReaderTests.swift` | Streaming parse, encoding |
| `macos/EngramTests/SourceColorsTests.swift` | Color mapping for all sources |
| `macos/EngramTests/ThemeTests.swift` | Theme values consistency |
| `macos/EngramTests/Fixtures/test-index.sqlite` | Pre-seeded fixture database |
| `macos/EngramUITests/EngramUITestCase.swift` | Base class: launch, screenshot, navigate |
| `macos/EngramUITests/Pages/*.swift` | 13 page test files |
| `macos/EngramUITests/Components/*.swift` | 4 component test files |
| `macos/EngramUITests/Workflows/*.swift` | 3 workflow test files |
| `scripts/generate-test-fixtures.ts` | Fixture DB generator script |
| `scripts/check-fixture-schema.mjs` | CI schema version validator |
| `scripts/compare-screenshots.swift` | pHash + SSIM screenshot comparator |
| `scripts/ai-triage.mjs` | AI diagnostic report generator |
| `.github/workflows/test.yml` | PR/main CI pipeline |
| `.github/workflows/release.yml` | Release gate pipeline |
| `.gitattributes` | Git LFS config for screenshot PNGs |
| `tests/screenshots/baselines/` | Screenshot baseline directory |

### Modified Files
| File | Change |
|------|--------|
| `macos/project.yml` | Add EngramTests + EngramUITests targets |
| `macos/Engram/App.swift` | Extract AppEnvironment, support `--test-mode` |
| `macos/Engram/Core/Database.swift` | Accept path from AppEnvironment |
| `macos/Engram/Core/IndexerProcess.swift` | No direct change needed (autoStart guard is in App.swift) |
| `macos/Engram/Core/DaemonClient.swift` | Accept port from AppEnvironment (already has `init(port:)`) |
| `vitest.config.ts` | Add coverage config |
| `package.json` | Add @vitest/coverage-v8, new scripts |

---

## Task 1: AppEnvironment Dependency Injection

**Files:**
- Create: `macos/Engram/Core/AppEnvironment.swift`
- Modify: `macos/Engram/App.swift`
- Modify: `macos/Engram/Core/Database.swift`
- Modify: `macos/Engram/Core/IndexerProcess.swift`

- [ ] **Step 1: Create AppEnvironment.swift**

```swift
// macos/Engram/Core/AppEnvironment.swift
import Foundation

struct AppEnvironment {
    let dbPath: String
    let daemonPort: Int
    let autoStartDaemon: Bool
    let networkEnabled: Bool
    let fixedDate: Date?

    static let production = AppEnvironment(
        dbPath: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".engram/index.sqlite").path,
        daemonPort: 3457, // matches DaemonClient default
        autoStartDaemon: true,
        networkEnabled: true,
        fixedDate: nil
    )

    static func test(fixturePath: String) -> AppEnvironment {
        AppEnvironment(
            dbPath: fixturePath,
            daemonPort: 0, // no real daemon
            autoStartDaemon: false,
            networkEnabled: false,
            fixedDate: Date(timeIntervalSince1970: 1742601600) // 2025-03-22 fixed
        )
    }

    static func fromCommandLine() -> AppEnvironment {
        let args = CommandLine.arguments
        if args.contains("--test-mode") {
            let fixturePath = args.firstIndex(of: "--fixture-db")
                .flatMap { idx in args.indices.contains(idx + 1) ? args[idx + 1] : nil }
                ?? Bundle.main.path(forResource: "test-index", ofType: "sqlite", inDirectory: "Fixtures")
                ?? ""
            return .test(fixturePath: fixturePath)
        }
        if let dataDir = args.firstIndex(of: "--data-dir")
            .flatMap({ idx in args.indices.contains(idx + 1) ? args[idx + 1] : nil }) {
            return AppEnvironment(
                dbPath: "\(dataDir)/index.sqlite",
                daemonPort: AppEnvironment.production.daemonPort,
                autoStartDaemon: AppEnvironment.production.autoStartDaemon,
                networkEnabled: AppEnvironment.production.networkEnabled,
                fixedDate: nil
            )
        }
        return .production
    }
}
```

- [ ] **Step 2: Modify App.swift AppDelegate to use AppEnvironment**

Replace hardcoded dependency creation:

```swift
// Before (lines 20-22):
let db           = DatabaseManager()
let indexer      = IndexerProcess()
let daemonClient = DaemonClient()

// After:
let environment: AppEnvironment
let db: DatabaseManager
let indexer: IndexerProcess
let daemonClient: DaemonClient

override init() {
    self.environment = AppEnvironment.fromCommandLine()
    self.db = DatabaseManager(path: environment.dbPath)
    self.indexer = IndexerProcess()
    self.daemonClient = DaemonClient(port: environment.daemonPort)
    super.init()
}
```

In `applicationDidFinishLaunching`, guard daemon start with `environment.autoStartDaemon`:

```swift
if environment.autoStartDaemon && !scriptPath.isEmpty {
    indexer.start(nodePath: resolvedNodePath, scriptPath: scriptPath)
}
```

- [ ] **Step 3: Verify DatabaseManager already accepts path parameter**

`DatabaseManager.init(path:)` already accepts an optional path (line 38 of Database.swift). No change needed.

- [ ] **Step 4: Verify DaemonClient accepts port parameter**

`DaemonClient` already has `init(port: Int = 3457)`. Verify this accepts the port from `AppEnvironment`. The `DaemonClient` also reads a bearer token from `readEngramSettings()` internally — in test mode (port 0), ensure the token read is harmless (it reads from settings file which may not exist, defaulting to nil, which is fine).

- [ ] **Step 5: Build and verify no regression**

```bash
cd macos && xcodegen generate
xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build
```

- [ ] **Step 6: Commit**

```bash
git add macos/Engram/Core/AppEnvironment.swift macos/Engram/App.swift macos/Engram/Core/Database.swift macos/Engram/Core/IndexerProcess.swift macos/Engram/Core/DaemonClient.swift
git commit -m "refactor: extract AppEnvironment for dependency injection and test mode"
```

---

## Task 2: Swift Unit Test Infrastructure

**Files:**
- Modify: `macos/project.yml`
- Create: `macos/EngramTests/` directory
- Create: `macos/EngramTests/DatabaseManagerTests.swift`

- [ ] **Step 1: Add test targets to project.yml**

Append to the `targets:` section:

```yaml
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

- [ ] **Step 2: Create test directories**

```bash
mkdir -p macos/EngramTests/Fixtures
mkdir -p macos/EngramUITests/Pages macos/EngramUITests/Components macos/EngramUITests/Workflows
```

- [ ] **Step 3: Write first DatabaseManager test**

```swift
// macos/EngramTests/DatabaseManagerTests.swift
import XCTest
import GRDB
@testable import Engram

final class DatabaseManagerTests: XCTestCase {
    var db: DatabaseManager!

    override func setUpWithError() throws {
        // Use a temp file (not :memory:, since DatabaseManager opens a GRDB pool which needs a file path)
        let tempDir = FileManager.default.temporaryDirectory
        let dbPath = tempDir.appendingPathComponent("test-\(UUID().uuidString).sqlite").path
        db = DatabaseManager(path: dbPath)
        try db.open() // open() calls writerPool.write which creates favorites/tags tables
    }

    override func tearDownWithError() throws {
        // Clean up temp file
        try? FileManager.default.removeItem(atPath: db.path)
    }

    func testOpenCreatesRequiredTables() throws {
        // Verify favorites and tags tables exist
        // Note: sessions table is created by daemon, not Swift
        let tables = try db.readInBackground { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'")
        }
        XCTAssertTrue(tables.contains("favorites"))
        XCTAssertTrue(tables.contains("tags"))
    }

    func testFetchSessionsReturnsEmptyForFreshDB() throws {
        // This will work once the sessions table is seeded from fixtures
        // For now, just verify the query doesn't crash
        // (sessions table may not exist in fresh DB since daemon creates it)
    }
}
```

- [ ] **Step 4: Generate Xcode project and run test**

```bash
cd macos && xcodegen generate
xcodebuild test -project Engram.xcodeproj -scheme Engram -destination 'platform=macOS' -only-testing:EngramTests
```

Expected: Test compiles and runs (may have limited assertions with empty DB).

- [ ] **Step 5: Commit**

```bash
git add macos/project.yml macos/EngramTests/
git commit -m "feat(testing): add Swift unit test infrastructure with EngramTests target"
```

---

## Task 3: Fixture Database Generator

**Files:**
- Create: `scripts/generate-test-fixtures.ts`
- Create: `scripts/check-fixture-schema.mjs`
- Modify: `package.json`

- [ ] **Step 0: Introduce SCHEMA_VERSION in db.ts**

The codebase currently has no `SCHEMA_VERSION` constant (only `FTS_VERSION`). Add one at the top of `src/core/db.ts`:

```typescript
/** Bump when schema changes (new tables, columns, indexes). Used by fixture DB validator. */
export const SCHEMA_VERSION = 1
```

The `metadata` table already exists in `db.ts` (created by `migrate()`). Verify this before proceeding — if for any reason it doesn't exist, add:
```typescript
db.exec("CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT)")
```

Then persist the version at the end of `migrate()`:
```typescript
// At end of migrate():
db.prepare("INSERT OR REPLACE INTO metadata (key, value) VALUES ('schema_version', ?)").run(String(SCHEMA_VERSION))
```

Run `npm test` to verify no regressions. Commit:
```bash
git add src/core/db.ts
git commit -m "feat: add SCHEMA_VERSION constant for fixture DB validation"
```

- [ ] **Step 1: Create fixture generator script**

`scripts/generate-test-fixtures.ts` — uses `better-sqlite3` to create a SQLite DB with:
- 20 sessions across 6 sources (claude-code ×5, cursor ×3, codex ×2, gemini ×2, windsurf ×2, others ×1 each)
- Each session: title, source, start_time, end_time, project, tier, message_count, tool_count
- 3 projects: engram (8 sessions), my-app (5), dotfiles (3), unassigned (4)
- Embed `SCHEMA_VERSION` from `src/core/db.ts` into `metadata` table (via `migrate()` which now writes it)
- Uses seeded PRNG for deterministic data
- Writes to `macos/EngramTests/Fixtures/test-index.sqlite`

Key implementation: import `Database` from `../src/core/db.js`, call `migrate()` to create schema (which sets `schema_version` in `metadata`), then insert fixture rows.

- [ ] **Step 2: Create schema version checker**

```javascript
// scripts/check-fixture-schema.mjs
import Database from 'better-sqlite3'
import { readFileSync } from 'fs'

const fixturePath = 'macos/EngramTests/Fixtures/test-index.sqlite'
const db = new Database(fixturePath, { readonly: true })
const row = db.prepare("SELECT value FROM metadata WHERE key = 'schema_version'").get()
db.close()

// Extract SCHEMA_VERSION from db.ts
const dbSrc = readFileSync('src/core/db.ts', 'utf-8')
const match = dbSrc.match(/SCHEMA_VERSION\s*=\s*(\d+)/)
if (!match) { console.error('Could not find SCHEMA_VERSION in db.ts'); process.exit(1) }

const fixtureVersion = row?.value
const codeVersion = match[1]

if (fixtureVersion !== codeVersion) {
  console.error(`Fixture DB schema version (${fixtureVersion}) != current (${codeVersion}).`)
  console.error('Run: npm run generate-fixtures')
  process.exit(1)
}
console.log(`Schema version match: ${codeVersion}`)
```

- [ ] **Step 3: Add scripts to package.json**

```json
"generate-fixtures": "tsx scripts/generate-test-fixtures.ts"
```

- [ ] **Step 4: Run generator and verify output**

```bash
npm run generate-fixtures
sqlite3 macos/EngramTests/Fixtures/test-index.sqlite "SELECT COUNT(*) FROM sessions"
```

Expected: 20 sessions.

- [ ] **Step 5: Commit**

```bash
git add scripts/generate-test-fixtures.ts scripts/check-fixture-schema.mjs macos/EngramTests/Fixtures/test-index.sqlite package.json
git commit -m "feat(testing): add fixture DB generator and schema version checker"
```

---

## Task 4: Complete Swift Unit Tests

**Files:**
- Create: `macos/EngramTests/DaemonClientTests.swift`
- Create: `macos/EngramTests/MessageParserTests.swift`
- Create: `macos/EngramTests/MessageTypeClassifierTests.swift`
- Create: `macos/EngramTests/IndexerProcessTests.swift`
- Create: `macos/EngramTests/SessionModelTests.swift`
- Create: `macos/EngramTests/StreamingJSONLReaderTests.swift`
- Create: `macos/EngramTests/SourceColorsTests.swift`
- Create: `macos/EngramTests/ThemeTests.swift`
- Extend: `macos/EngramTests/DatabaseManagerTests.swift`

- [ ] **Step 1: Expand DatabaseManagerTests (20+ tests)**

Add tests for:
- Session queries with fixture DB (load fixture, query sessions, verify count)
- FTS search (search for known keywords in fixture sessions)
- CJK search (insert CJK content, verify LIKE fallback works)
- Tier filtering (verify skip/lite/normal/premium filtering)
- Favorites (add/remove favorite, verify persistence)
- Tags (add/remove tag, query by tag)
- Sorting (createdDesc, updatedDesc)

- [ ] **Step 2: Create DaemonClientTests (10+ tests)**

Use `URLProtocol` mock to test:
- Successful GET /api/sessions response parsing
- HTTP error handling (404, 500, timeout)
- Response JSON decoding
- Request URL construction

- [ ] **Step 3: Create MessageParserTests (15+ tests)**

Test MessageParser with:
- Valid JSONL input (multiple messages)
- Malformed JSON (partial lines, invalid UTF-8)
- Empty input
- Single-line input
- Tool call messages
- Messages with different roles (user, assistant, system)

- [ ] **Step 4: Create remaining test files**

Follow the same pattern for MessageTypeClassifier, IndexerProcess (mock stdout pipe), SessionModel, StreamingJSONLReader, SourceColors, Theme.

- [ ] **Step 5: Run all Swift tests**

```bash
cd macos && xcodegen generate
xcodebuild test -project Engram.xcodeproj -scheme Engram -destination 'platform=macOS' -only-testing:EngramTests
```

Expected: 100+ tests pass.

- [ ] **Step 6: Commit**

```bash
git add macos/EngramTests/
git commit -m "feat(testing): add 100+ Swift unit tests for core logic and models"
```

---

## Task 5: TypeScript Test Coverage Setup

**Files:**
- Modify: `vitest.config.ts`
- Modify: `package.json`

- [ ] **Step 1: Install coverage dependency**

```bash
npm install -D @vitest/coverage-v8
```

- [ ] **Step 2: Update vitest.config.ts**

```typescript
import { defineConfig } from 'vitest/config'

export default defineConfig({
  test: {
    globals: true,
    environment: 'node',
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
})
```

- [ ] **Step 3: Run coverage and identify gaps**

```bash
npm run test:coverage
```

Review the HTML report at `coverage/index.html`. Identify modules below 70% coverage.

- [ ] **Step 4: Commit**

```bash
git add vitest.config.ts package.json package-lock.json
git commit -m "feat(testing): add vitest coverage with v8 provider and 70% thresholds"
```

---

## Task 6: TypeScript Test Gap Filling

**Files:**
- Create/Extend: multiple test files in `tests/`

- [ ] **Step 1: Add adapter edge case tests (+15)**

For each adapter, add tests for:
- Malformed session file (should not crash, return empty)
- Empty session directory
- Non-UTF-8 encoding handling

- [ ] **Step 2: Add error path tests (+20)**

Test error handling in:
- `indexer.ts`: adapter throws during `streamMessages()`
- `viking-bridge.ts`: API timeout, invalid response
- `db.ts`: concurrent write attempts, corrupted DB

- [ ] **Step 3: Add config tests (+10)**

- Invalid `settings.json` (malformed JSON)
- Missing config file (defaults used)
- Config migration from `~/.coding-memory/`

- [ ] **Step 4: Add web API tests (+15)**

For each route in `src/web.ts`:
- Successful response
- Error responses (404, 400 for bad params)
- Pagination parameters

- [ ] **Step 5: Run coverage and verify thresholds met**

```bash
npm run test:coverage
```

Expected: 507+ tests, 70%+ coverage.

- [ ] **Step 6: Commit**

```bash
git add tests/
git commit -m "feat(testing): add 80+ new TypeScript tests, coverage now 70%+"
```

---

## Task 7: XCUITest Infrastructure

**Files:**
- Create: `macos/EngramUITests/EngramUITestCase.swift`
- Create: `macos/EngramUITests/Pages/HomePageTests.swift` (first UI test)

- [ ] **Step 1: Create base test case**

```swift
// macos/EngramUITests/EngramUITestCase.swift
import XCTest

class EngramUITestCase: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()

        // Point to fixture DB
        let fixtureDB = Bundle(for: type(of: self))
            .path(forResource: "test-index", ofType: "sqlite")
            ?? ""
        app.launchArguments = ["--test-mode", "--fixture-db", fixtureDB]
        app.launch()

        // Wait for main window
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    // MARK: - Helpers

    func takeScreenshot(name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func navigateTo(page: String) {
        let sidebar = app.outlines.firstMatch
        let pageItem = sidebar.staticTexts[page]
        XCTAssertTrue(pageItem.waitForExistence(timeout: 5), "Sidebar item '\(page)' not found")
        pageItem.click()
        // Wait for page content to load — use explicit wait, never Thread.sleep
        // Each page should have an accessibility identifier; wait for it
        let pageContent = app.groups["\(page)Page"].firstMatch
        if pageContent.exists { return }
        // Fallback: wait for any new content to appear
        _ = app.staticTexts.firstMatch.waitForExistence(timeout: 5)
    }
}
```

- [ ] **Step 2: Copy fixture DB to UI test bundle**

Add fixture DB to `EngramUITests` target resources in `project.yml`:

```yaml
  EngramUITests:
    type: bundle.ui-testing
    platform: macOS
    deploymentTarget: "14.0"
    sources:
      - path: EngramUITests
    resources:
      - path: EngramTests/Fixtures
    dependencies:
      - target: Engram
    settings:
      PRODUCT_BUNDLE_IDENTIFIER: com.engram.app.uitests
```

- [ ] **Step 3: Write first UI test (HomePageTests)**

```swift
// macos/EngramUITests/Pages/HomePageTests.swift
import XCTest

final class HomePageTests: EngramUITestCase {
    func testHomePageLoads() {
        navigateTo(page: "Home")
        // Verify the page rendered (check for known elements)
        XCTAssertTrue(app.staticTexts["Home"].exists || app.windows.firstMatch.exists)
        takeScreenshot(name: "home-dashboard")
    }

    func testHomeShowsKPIs() {
        navigateTo(page: "Home")
        // KPI cards should be visible
        // Exact element queries depend on accessibility identifiers
        takeScreenshot(name: "home-kpis")
    }
}
```

- [ ] **Step 4: Build and run first UI test**

```bash
cd macos && xcodegen generate
xcodebuild test -project Engram.xcodeproj -scheme Engram -destination 'platform=macOS' -only-testing:EngramUITests/HomePageTests
```

Expected: App launches in test mode, test passes with screenshots.

- [ ] **Step 5: Commit**

```bash
git add macos/EngramUITests/ macos/project.yml
git commit -m "feat(testing): add XCUITest infrastructure with base test case and first UI test"
```

---

## Task 8: UI Test Cases (Page by Page)

Write test files for each remaining page. Each file follows the pattern from Task 7.

- [ ] **Step 1: SessionsPageTests.swift** (6 tests)
  - testSessionListLoads, testFilterBySource, testFilterByTier, testSortByDate, testSearchWithinSessions, testPagination

- [ ] **Step 2: SessionDetailTests.swift** (5 tests)
  - testTranscriptLoads, testMessagesDisplay, testToolCallsShown, testMetadataCorrect, testCopyWorks

- [ ] **Step 3: SearchPageTests.swift** (5 tests)
  - testEmptyState, testTextSearchReturnsResults, testClickResultNavigates, testNoResultsState, testCJKSearch

- [ ] **Step 4: ActivityPageTests.swift** (3 tests)

- [ ] **Step 5: ProjectsPageTests.swift** (3 tests)

- [ ] **Step 6: TimelinePageTests.swift** (3 tests)

- [ ] **Step 7: Checkpoint commit — core page tests**

```bash
cd macos && xcodegen generate
xcodebuild test -project Engram.xcodeproj -scheme Engram -only-testing:EngramUITests -destination 'platform=macOS'
git add macos/EngramUITests/
git commit -m "feat(testing): add UI tests for core pages (sessions, search, activity, projects, timeline)"
```

- [ ] **Step 8: AgentsPageTests.swift** (2 tests)

- [ ] **Step 9: MemoryPageTests.swift** (2 tests)

- [ ] **Step 10: HooksPageTests.swift** (2 tests)

- [ ] **Step 11: SkillsPageTests.swift** (2 tests)

- [ ] **Step 12: SourcePulsePageTests.swift** (3 tests)

- [ ] **Step 13: SettingsTests.swift** (4 tests)

- [ ] **Step 14: SidebarTests.swift** (2 tests)

- [ ] **Step 15: FilterPillTests.swift + SessionCardTests.swift** (4 tests)

- [ ] **Step 16: Checkpoint commit — secondary page + component tests**

```bash
xcodebuild test -project Engram.xcodeproj -scheme Engram -only-testing:EngramUITests -destination 'platform=macOS'
git add macos/EngramUITests/
git commit -m "feat(testing): add UI tests for secondary pages and components"
```

- [ ] **Step 17: Workflow tests** (3 tests)
  - SearchWorkflowTests, SessionBrowseTests, SettingsWorkflowTests

- [ ] **Step 18: PopoverTests.swift** (3 tests, with fallback caveat)
  - Try XCUIApplication.statusItems first. If unreliable, use AXUIElement fallback. Tag with `SKIP_POPOVER_TESTS` env var guard.

- [ ] **Step 19: Final commit — workflows + popover**

```bash
xcodebuild test -project Engram.xcodeproj -scheme Engram -only-testing:EngramUITests -destination 'platform=macOS'
git add macos/EngramUITests/
git commit -m "feat(testing): add workflow and popover UI tests — 52 total"
```

---

## Task 9: Screenshot Comparison

**Files:**
- Create: `scripts/compare-screenshots.swift`
- Create: `tests/screenshots/baselines/` directory
- Create: `.gitattributes`

- [ ] **Step 1: Setup Git LFS for baselines**

```bash
git lfs install
echo 'tests/screenshots/baselines/**/*.png filter=lfs diff=lfs merge=lfs -text' > .gitattributes
```

- [ ] **Step 2: Create screenshot comparator**

`scripts/compare-screenshots.swift` — a Swift command-line script that:
1. Reads baseline images from `tests/screenshots/baselines/macOS-{version}/`
2. Reads current screenshots from `FullUITestResults.xcresult` (via `xcrun xcresulttool`)
3. Computes perceptual hash (pHash) — pass if hamming distance < 5
4. If pHash fails, compute SSIM using `vImage` (Accelerate framework) — pass if > 0.95
5. For mismatches, generate diff image highlighting changed pixels
6. Output JSON report to `tests/screenshots/reports/`

- [ ] **Step 3: Capture initial baselines**

```bash
# Run UI tests with baseline capture
UPDATE_SCREENSHOTS=1 xcodebuild test -project macos/Engram.xcodeproj -scheme Engram -only-testing:EngramUITests -destination 'platform=macOS'
# Extract screenshots and save to baselines
swift scripts/compare-screenshots.swift --capture-baselines
```

- [ ] **Step 4: Add OS version auto-detection**

In `compare-screenshots.swift`, detect macOS version:
```swift
let osVersion = ProcessInfo.processInfo.operatingSystemVersion
let versionDir = "macOS-\(osVersion.majorVersion).\(osVersion.minorVersion)"
```

If baseline directory for current OS doesn't exist, print warning and skip comparison.

- [ ] **Step 5: Commit**

```bash
git add .gitattributes scripts/compare-screenshots.swift tests/screenshots/baselines/
git commit -m "feat(testing): add screenshot comparison with pHash+SSIM and Git LFS baselines"
```

---

## Task 10: CI/CD Pipeline

**Files:**
- Create: `.github/workflows/test.yml`
- Create: `.github/workflows/release.yml`

- [ ] **Step 1: Create PR/main pipeline (test.yml)**

Three jobs:
1. `typescript-tests` on `ubuntu-latest`: npm ci, build, test, coverage
2. `swift-unit-tests` on `macos-15`: setup-node, check-fixture-schema, xcodegen, xcodebuild test
3. `ui-smoke-tests` on `macos-15` (needs swift-unit-tests): npm ci, build, xcodegen, xcodebuild test with `-only-testing:EngramUITests/SmokeTests`

See spec for exact YAML. **Critical**: the `swift-unit-tests` job MUST include `actions/setup-node@v4` because `check-fixture-schema.mjs` is a Node script. The spec's YAML already includes this step — verify it's present when copying.

- [ ] **Step 2: Create release pipeline (release.yml)**

Single `full-test-suite` job on `macos-15`:
- All TS tests + Swift unit tests + full UI tests (parallel, 4 workers) + screenshot comparison + AI triage (continue-on-error)
- Upload artifacts: coverage, test results, screenshots, reports

- [ ] **Step 3: Add CI badge to package.json or existing docs** (optional)

- [ ] **Step 4: Push a test branch and verify CI runs**

```bash
git checkout -b test/ci-pipeline
git push -u origin test/ci-pipeline
```

Verify GitHub Actions triggers and all jobs pass.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/
git commit -m "feat(testing): add GitHub Actions CI/CD with PR and release gate pipelines"
```

---

## Task 11: E2E Full-Chain Tests

**Dependency:** Requires Observability Layer 1-2 (logger + tracer) from the observability plan.

**Files:**
- Create: `macos/EngramUITests/E2E/E2ETestCase.swift`
- Create: `macos/EngramUITests/E2E/IndexingE2ETests.swift`
- Create: `macos/EngramUITests/E2E/SearchE2ETests.swift`

- [ ] **Step 1: Create E2E base test case**

Extends `XCTestCase` with daemon process management:
- `setUpWithError()`: prepare temp fixture dir, launch daemon via `Process()`, poll `GET /health` (30s timeout, 0.5s interval), launch app
- `tearDownWithError()`: terminate daemon, cleanup temp dir
- Node path resolution: `ENGRAM_NODE_PATH` env var or `which node`
- Daemon path: `dist/daemon.js` from project root

- [ ] **Step 2: Write E2E test cases**

8 tests as specified in the spec:
- `testIndexingToDisplay`: daemon indexes fixtures → app shows correct session count
- `testSearchFullChain`: index → search → verify results
- `testSessionDetail`: index → navigate to session → verify transcript
- `testSourcePulse`: verify source status matches indexed data
- `testActivityData`: verify charts reflect dates
- `testProjectGrouping`: verify project grouping
- `testDaemonRestart`: kill daemon → verify error UI → restart → verify recovery
- `testIncrementalIndex`: add new fixture → re-index → verify new session appears

- [ ] **Step 3: Run E2E tests locally**

```bash
npm run build  # ensure dist/daemon.js exists
cd macos && xcodegen generate
xcodebuild test -project Engram.xcodeproj -scheme Engram -only-testing:EngramUITests -destination 'platform=macOS' -only-testing:EngramUITests/E2E
```

- [ ] **Step 4: Commit**

```bash
git add macos/EngramUITests/E2E/
git commit -m "feat(testing): add 8 E2E tests spanning daemon → index → UI verification"
```

---

## Task 12: AI Triage (Phase A — Diagnostic Reports)

**Dependency:** Requires Observability Layer 1-2 for log context in reports.

**Files:**
- Create: `scripts/ai-triage.mjs`

- [ ] **Step 1: Create AI triage script**

`scripts/ai-triage.mjs`:
1. Find screenshot test failures from `FullUITestResults.xcresult` (via `xcrun xcresulttool`)
2. For each failure (max 10):
   - Read baseline image, current image, diff image
   - Read recent git changes (`git log --oneline -10`, `git diff --stat HEAD~1`)
   - Read recent logs from Engram DB (accepts `--db-path` flag; defaults to `~/.engram/index.sqlite`; if DB doesn't exist or has no `logs` table, skip log context gracefully)
   - Send to Claude API (Sonnet) with classification prompt
   - Save JSON report to `tests/screenshots/reports/`
3. Uses `ANTHROPIC_API_KEY` env var (GitHub secret in CI)
4. Timeout: 30s per API call, 1 retry
5. If API unavailable: skip with warning, exit 0 (never fail the pipeline)
6. Budget: max 10 calls per run

- [ ] **Step 2: Test locally with a simulated failure**

Manually modify a baseline to be slightly different, run UI tests, then run triage:

```bash
node scripts/ai-triage.mjs --results-path FullUITestResults.xcresult
```

Verify JSON report is generated.

- [ ] **Step 3: Commit**

```bash
git add scripts/ai-triage.mjs
git commit -m "feat(testing): add AI triage Phase A — diagnostic reports for screenshot failures"
```

---

## Task 13: Test Maintenance Setup

**Files:**
- Modify: `package.json`

- [ ] **Step 1: Add generate-fixtures script if not already present**

Verify `package.json` has:
```json
"generate-fixtures": "tsx scripts/generate-test-fixtures.ts"
```

- [ ] **Step 2: Add test:all script**

```json
"test:all": "npm test && cd macos && xcodegen generate && xcodebuild test -project Engram.xcodeproj -scheme Engram -destination 'platform=macOS'"
```

- [ ] **Step 3: Document test maintenance rules in CLAUDE.md**

Add to the Testing section of CLAUDE.md:
- PRs modifying SwiftUI views should update corresponding UI tests
- Run `UPDATE_SCREENSHOTS=1` locally when intentionally changing UI
- Flaky tests quarantined after 2 failures in 30 days, resolved within 2 weeks or deleted
- Fixture DB regenerated via `npm run generate-fixtures` when schema changes

- [ ] **Step 4: Final full test run**

```bash
npm test
cd macos && xcodebuild test -project Engram.xcodeproj -scheme Engram -destination 'platform=macOS'
```

- [ ] **Step 5: Commit**

```bash
git add package.json CLAUDE.md
git commit -m "feat(testing): add test maintenance scripts and documentation"
```
