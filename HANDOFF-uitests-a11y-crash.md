# Handoff — EngramUITests accessibility-snapshot crash (7 remaining failures)

**Date:** 2026-05-22
**Author:** Claude (round-5 remediation session) + Codex
**Status:** ✅ RESOLVED — EngramUITests fully green (0 failures)

## RESOLUTION (2026-05-22)

All 18 EngramUITests pass. Three-part fix (Claude + Codex collaboration):

1. **Crash (Codex):** typed XCUITest queries instead of
   `descendants(matching: .any)`. Added `button(id:)`/`group(id:)`/
   `scrollView(id:)` helpers in `WaitUtils.swift`; applied in
   `SidebarScreen.swift` and `SettingsScreen.swift`. `.any` forces a full,
   ~1600-deep AX snapshot that stack-overflows on macOS 26.5; typed collection
   queries don't.
2. **Footer not exposed (Codex):** `.accessibilityElement(children: .contain)`
   on the `SidebarFooter` HStack (`SidebarView.swift`). SwiftUI's AX merge
   heuristic had collapsed the footer subtree (decorative `Rectangle` divider),
   hiding the Settings/Theme buttons.
3. **Source-distribution legend collapsed (Claude):** same `.contain` fix on the
   `home_dailyChart` VStack (`HomeView.swift`) so the `home_sourceDistribution`
   legend (a child) surfaces. Also reverted an over-applied typed-query change
   in `HomeScreen.swift` (Home content elements are VStacks, found fine via
   `.any`, and don't trigger the crash).

Lesson for future SwiftUI a11y / XCUITest on macOS 26: avoid
`descendants(matching: .any)` for id lookups (use typed collection queries), and
containers with a decorative sibling + `.accessibilityIdentifier` may collapse
their children — add `.accessibilityElement(children: .contain)` to re-expose.

---

Original handoff (historical) below.

**Branch:** `main`

---

## PROGRESS UPDATE (2026-05-22, after Codex pass)

**The crash is FIXED.** Codex replaced the crashing `descendants(matching: .any)`
full-tree queries with typed queries (`buttons[id]` / `groups[id]` /
`scrollViews[id]`) in `WaitUtils.swift`, `SidebarScreen.swift`,
`SettingsScreen.swift`, `HomeScreen.swift`. Verified on hardware:
`testSettingsReachable` now runs ~18s with **no crash** (was a Bus error).
Typed collection queries don't trigger the deep all-descendants snapshot.

**One blocker remains (app-side, not the crash):** the `SidebarFooter` buttons
are not exposed to XCUITest at all. Crash-safe probes (no `.any`) show:
- `sidebar_item_settings` / `sidebar_themeToggle`: not found as button / group /
  staticText / otherElements / image / cell — on Home AND after navigating to
  the shallow Sessions screen; also not found by label (`buttons["Settings"]`,
  `buttons["Theme"]` = false).
- Sidebar LIST items DO resolve: `sidebar_item_sessions` / `sidebar_item_home`
  are `buttons=true`. `app.buttons.count` = 30 (Home) / 44 (Sessions).

So the footer Settings/Theme buttons in `SidebarView.swift` `SidebarFooter`
(body ~line 76, two `footerButton(...)` in an `HStack{...}.frame(height: 28)`
after a `Divider`) need an app-side accessibility-exposure fix so XCUITest can
find/click them — without changing visible layout. This is what Codex is
finishing; Claude verifies via the full `EngramUITests` run.

Original analysis (still valid background) follows.

---

## TL;DR

Round-5 review remediation is **done and committed** (2 commits below). While
getting the suite green I restored most of `EngramUITests` (18 → 7 failures),
but **7 UI tests still fail** because XCUITest's accessibility snapshot
**crashes the app process** (`Bus error` in `__CFStringDeallocate`) while
enumerating a ~1600-deep accessibility tree. I proved the app's *own* AppKit
accessibility tree is shallow/healthy, so this is a **SwiftUI ↔ XCUITest
tooling-level crash on macOS 26.5**, not an app view-nesting bug. It needs a
decision + targeted work; details below.

---

## Commits already landed (do not redo)

- `a1f6369e` — `fix: remediate round-5 fresh-angle review findings (61) + parity closeout`
  - All 61 round-5 findings (`review-round5.md`), 3 pre-existing test fixes
    (ping-tier assertion, `session_costs.model` NULL parity, FTS retryPolicy),
    handoff MCP parity revert.
  - Green: `npm test` 1395; Swift `Engram` + `EngramServiceCore` (44) +
    `EngramMCPTests` (46).
- `9eb932fc` — `fix: restore EngramUITests data loading (18 -> 7 failures)`
  - Three real root causes fixed: UITests bundled the wrong fixture dir;
    `AppEnvironment.fromCommandLine` short-circuited `--test-mode`; stale
    fixture schema (regenerated `test-fixtures/test-index.sqlite`).

Working tree is clean at `9eb932fc`. All my diagnostic scaffolding was removed.

---

## The remaining 7 failing tests

All in target `EngramUITests` (scheme `Engram`, also runnable via the
`Engram` scheme test action):

| Test | File |
|------|------|
| `testSectionNavigationItems` | `macos/EngramUITests/Tests/FullTests/SettingsTests.swift` |
| `testGeneralSection` | same |
| `testNetworkSettings` | same |
| `testAboutSection` | same |
| `testSettingsReachable` | `macos/EngramUITests/Tests/FullTests/NavigationTests.swift` |
| `testSettingsDark` | `macos/EngramUITests/Tests/FullTests/DarkModeTests.swift` |
| `testSourceDistribution` | `macos/EngramUITests/Tests/FullTests/HomeTests.swift` |

6 of 7 funnel through `SidebarScreen.navigateToSettings()`
(`macos/EngramUITests/Screens/SidebarScreen.swift:43-52`), which resolves the
Settings sidebar-footer item via
`app.element(id: "sidebar_item_settings")`. `element(id:)`
(`macos/EngramUITests/Helpers/WaitUtils.swift:8`) is
`descendants(matching: .any)[identifier].firstMatch` — a full-tree query.

`testSourceDistribution` is on the Home screen and fails the same way
(`SidebarScreen.swift:31`, "Sidebar item 'home' not found").

---

## Reproduce

```bash
# one fast failing case (~70s; app crashes mid-snapshot)
xcodebuild test -project macos/Engram.xcodeproj -scheme Engram \
  -configuration Debug -destination 'platform=macOS' \
  -only-testing:EngramUITests/NavigationTests/testSettingsReachable

# full UITests (slower): -only-testing:EngramUITests  → 7 failures
```

Failure signature in the log:
```
<unknown>:0: error: -[EngramUITests.NavigationTests testSettingsReachable] : com.engram.app crashed in <external symbol>
```

Crash report (representative):
`~/Library/Logs/DiagnosticReports/Engram-2026-05-22-164739.ips`
- `termination`: `SIGNAL` code 10, **Bus error: 10**.
- Main thread crash frame: `__CFStringDeallocate` → `objc_autoreleasePoolPop`
  → `-[NSApplication run]`.
- Triggered worker thread (`com.apple.dt.xctautomationsupport`):
  `_XCElementSnapshotEnumerateDescendantsUsingBlock` recursing with
  `recursionInfoArray` `depth: 1271` and `depth: 1638`, `originalLength: 2927`,
  crashing in `objc_loadWeakRetained` / `-[XCElementSnapshot parent]`.
- OS: macOS 26.5 (25F71).

---

## What is already ruled out (don't repeat)

1. **Not a fixture/data problem.** Data loads correctly now (18 visible
   sessions). The 11 session/detail/data UI tests pass.
2. **Not Home's content sections.** I added `.accessibilityHidden(true)` to
   `StackedActivityChart`, `HeatmapGrid`, and the entire `recentSessionsSection`
   in `macos/Engram/Views/Pages/HomeView.swift` — **still crashed**. (Reverted.)
3. **Not an app view-nesting bug.** I added a temporary in-process
   `AccessibilityTreeDumper` (walks `NSApp.windows` via AppKit
   `accessibilityChildren()`, depth-capped) and ran the built binary directly
   with `--dump-a11y` (no XCUITest). Result:
   `MAX_DEPTH=6  NODE_COUNT=96  WINDOWS=2`. The app's AppKit-level a11y tree is
   shallow and healthy. (Dumper removed.)

**Conclusion:** the ~1600-deep tree exists only in XCUITest's AX snapshot
expansion of the SwiftUI hierarchy. SwiftUI exposes an opaque element to AppKit,
so in-process AppKit walking can't see (or pinpoint) the deep subtree, and the
external AX path that *can* see it is exactly what crashes. Session/detail tests
pass because their `firstMatch` short-circuits before reaching the offending
subtree; the Settings footer sits later in traversal order.

---

## Suggested next steps (pick one)

### Option A — test-side workaround (no app change, uncertain)
Make the 7 tests avoid the broad `descendants(matching: .any)` full-tree
snapshot. Ideas, in rough order of promise:
- Scope the Settings query to the sidebar subtree only, e.g. resolve `sidebar`
  first, then `sidebar.buttons["sidebar_item_settings"]`, so XCUITest needn't
  expand the detail pane. (May still expand the whole tree — verify.)
- Drive Settings via a keyboard shortcut instead of a sidebar click. NOTE the
  app has a standard `Settings { SettingsView() }` scene (`macos/Engram/App.swift:56`)
  reachable via ⌘, — but that's a *separate window* from the in-window
  `selectedScreen == .settings` view the tests assert on
  (`SidebarView` footer button id `sidebar_item_settings`,
  `macos/Engram/Views/SidebarView.swift:82`). Reconcile before relying on it.
- For `testSourceDistribution`, same: query `home_sourceDistribution`
  (`HomeView.swift:125`) via a scoped/typed path.

### Option B — reduce SwiftUI a11y snapshot depth (app change)
Pinpoint the SwiftUI subtree XCUITest over-expands, using the **external AX C
API** from a separate process (this reproduces the crash, so cap recursion and
run against a *paused* app, or use Accessibility Inspector's element tree). Once
found, cap depth with `.accessibilityElement(children: .contain)` /
`.accessibilityHidden(true)` on the offending decorative subtree. Candidates not
yet ruled out: shared scaffolding (`MainWindowView`, the custom
`modernScrollIndicators()` `NSViewRepresentable` in
`macos/Engram/Components/Theme.swift`), the detail-pane container, or a
SwiftUI/macOS-26 a11y interaction. My earlier guesses (charts, recent sessions)
were wrong, so **instrument before editing** — don't shotgun modifiers.

### Option C — accept + track (recommended by me)
The app is healthy for real users/VoiceOver (shallow AppKit a11y tree). The 11
substantive UI tests pass. Treat the 7 as a tooling-level (macOS 26.5
SwiftUI/XCUITest) flake, track separately, and don't spend more cycles unless
CI stability demands it.

---

## Key files

- Test helper that triggers the crash: `macos/EngramUITests/Helpers/WaitUtils.swift:8`
- Sidebar nav: `macos/EngramUITests/Screens/SidebarScreen.swift`
- Settings footer button (the target): `macos/Engram/Views/SidebarView.swift:76-101` (`SidebarFooter`)
- Test-mode launch wiring: `macos/Engram/Core/AppEnvironment.swift` (`fromCommandLine`)
  and `macos/EngramUITests/Helpers/TestLaunchConfig.swift`
- Fixture DB: `test-fixtures/test-index.sqlite` (symlinked from `macos/test-fixtures/`),
  regenerated via `npm run generate:fixtures` (TS schema includes
  `parent_session_id` / `suggested_parent_id`).

## How to re-create the in-process a11y dumper (if Option B)
Add a `--dump-a11y` arg handler in `AppDelegate.applicationDidFinishLaunching`
that, after a delay, walks `NSApp.windows` via AppKit `accessibilityChildren()`
(depth-capped) and writes to a file — but note this only sees the *shallow*
AppKit tree (depth 6), NOT the deep XCUITest/AX tree, so it won't pinpoint the
culprit. For Option B you need the AX C API (`AXUIElementCopyAttributeValue`
with `kAXChildrenAttribute`) from a separate, recursion-capped process.
