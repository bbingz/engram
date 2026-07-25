# Design Doc: MCP Activation & Onboarding

- **Status**: Draft
- **Owner**: unassigned
- **Date**: 2026-07-24
- **Related**: `docs/competitive-mirror-2026-07.md` backlog rows 7 (UX-2 + F7),
  17 (UX-5), 24 (F7), 28 (UX-6). Composes with the concurrently-implemented
  baseline specs where files overlap: `docs/source-health-predicate-design-2026-07.md`
  (SourcePulseView / source predicate), `docs/codex-native-parentage-design-2026-07.md`
  (StartupBackfills — no overlap here, cross-referenced for the ledger). This
  spec touches none of those specs' hot files except `docs/invariants.md`
  (read-only for this spec — see Invariants affected).

All code citations are at HEAD `23dca547` (branch `docs/mirror-followup-specs`)
and were opened during authoring. Concurrent branches will drift the numbers;
re-anchor before implementing. Note the parallel-recon lenses ran on `382693db`
(two docs-only commits behind this HEAD); their Swift line numbers were
re-verified against `23dca547` and hold.

## Problem

A new user finishes onboarding without ever learning that Engram *is* an MCP
memory layer, cannot verify the MCP wiring, and cannot reach help. Four measured
gaps, each independently landable:

1. **Onboarding re-shows on every launch, forever.** The first-run gate reads
   `UserDefaults.bool("hasCompletedOnboarding")` (`macos/Engram/App.swift:199`),
   and that flag is written in exactly one place — `completeOnboarding()`
   (`App.swift:288`), reached only by the final "Open Engram" button
   (`OnboardingView.swift:198`). The onboarding `NSWindow` is created with
   `styleMask = [.titled, .closable, .fullSizeContentView]` (`App.swift:273`)
   and **no** `NSWindowDelegate` (`App.swift:262-285`). A user who closes the
   window instead of clicking the button never sets the flag, so onboarding
   reappears next launch, permanently. The same close path never runs the
   `.accessory` revert (`App.swift:293`), so the Dock icon set at `App.swift:280`
   stays for the session. Plus two content bugs in the same view: the Windsurf
   probe reads `~/.codeium/windsurf` (`OnboardingView.swift:228`) while the
   adapter reads `~/.engram/cache/windsurf` (`SourceCatalog.swift:41`), so
   Windsurf always shows "not found"; and the Settings MCP-helper path is a
   hardcoded `/Applications/…` literal (`SourcesSettingsSection.swift:544`) that
   breaks for any user who moved the app, next to a stale "Node MCP … legacy
   rollback path" sentence (`:606`) for a runtime that no longer ships.

2. **The app has no mouth.** `grep -rniE "github.com|report.*(issue|bug)|send
   feedback" macos/Engram --include="*.swift"` returns 0. There is no Help menu:
   `setupMainMenu()` builds only App/Edit/View/Window (`MenuBarController.swift:505-560`).
   `AboutSettingsSection` exports a diagnostics bundle to disk and stops
   (`AboutSettingsSection.swift:32-57`) — no way to attach it to anything.

3. **Onboarding never says "MCP."** `grep -rni "mcp" macos/Engram/Onboarding`
   returns 0. The Claude Code plugin shipped in `cb6bffc3` (17 files under
   `integrations/claude-code/`) with zero in-app surface. The one MCP setup UI,
   `MCPSetupGuideView`, is buried inside the Data Sources settings tab
   (`SourcesSettingsSection.swift:543`, rendered under a `GroupBox` at `:8,21-24`).

4. **MCP verification is a passive dot.** The only "is it wired?" signal is
   `PathExistsIndicator(path:)`, a bare `FileManager.fileExists`
   (`SourcesSettingsSection.swift:514-533`, used at `:600`): no exec bit, no
   handshake, no socket check. A user whose helper is present-but-not-executable,
   or whose service socket is down, sees a green dot and a silent failure.

(The mirror's own anchors for gaps 3/4 were off: `PathExistsIndicator` is at
`SourcesSettingsSection.swift:514-533`/`:600`, not `:599`/`:230-241`; the real
JSON-RPC handshake `invokeMCPGetContext` lives in
`EngramCLIContextCommand.swift:332`, not `SourcesSettingsSection.swift:335`; the
activation-policy revert is `App.swift:293`, not `:291` (`:290` is
`onboardingWindow = nil`, `:291` is a comment). Corrections recorded under
Current state.)

## Goals / Non-goals

**Goals**

- G1 (row 7): completing onboarding by *any* window-dismissal records completion
  and reverts activation policy; fix the Windsurf probe path; derive the MCP
  helper path from the running bundle; delete the dead Node sentence.
- G2 (row 17): a Help menu reachable in window mode with "Report an Issue"
  (prefilled GitHub URL carrying version+build) and "Show Onboarding"; an
  "Attach to an issue" affordance beside the diagnostics export.
- G3 (row 24): a HomeView activation card that appears only when the user has
  indexed sessions **and** no Engram MCP server is configured, explaining
  `get_context` / `search` / `save_insight` and linking the install guide; plus
  an onboarding step that names MCP.
- G4 (row 28): a user-initiated verification ladder that reports the first
  failing rung (resolve → exec bit → live handshake → service socket) with one
  specific remedy line.

**Non-goals**

- Moving MCP setup out of the Data Sources settings tab (the `sources-sync-3` IA
  move, `docs/reviews/alignment-design-2026-06-14.md`). Flagged, deferred.
- Detecting fresh-install by artifact/DB absence. The app itself opens
  `~/.engram/index.sqlite` at `App.swift:122` (`db.open()`) and starts the
  service at `:131` (guarded by `if environment.autoStartService` at `:127`),
  both *before* the onboarding gate at `:199` runs — so the DB exists by
  gate-time regardless of the spawn race. (`EngramServiceRunner.swift:122-127`
  only constructs the DB path string; it does not create the file.) The
  `hasCompletedOnboarding` flag stays the only completion signal.
- Auto-installing the plugin or silently mutating any MCP client config. The
  card explains and links; it does not write client config.
- A timer-driven or on-render MCP handshake. Verification (row 28) and the card's
  live-liveness checks are user-initiated only, matching the rival prior art
  (`as-main/AgentSessions/Preferences/PreferencesView+Usage.swift:658-661`
  `performTest` is user-initiated).
- Uploading diagnostics anywhere (row 17 stops at "attach to an issue" copy +
  reusing the existing on-disk export).
- Any TypeScript, schema, migration, or new SQLite writer. All four rows are
  UI/AppKit + read-only file/socket reads.

## Current state

Anchors verified at `23dca547` on 2026-07-24.

**Onboarding lifecycle (row 7).** `AppDelegate` is
`@MainActor class … : NSObject, NSApplicationDelegate` (`App.swift:68-69`) and
owns `onboardingWindow` (`:77`). `showOnboarding()` (`:262-285`) builds the
window, sets `isReleasedWhenClosed = false` (`:277`), `styleMask` with
`.closable` and no delegate (`:273`), `NSApp.setActivationPolicy(.regular)`
(`:280`). `completeOnboarding()` (`:287-295`) writes the flag (`:288`), closes
the window (`:289`), nils it (`:290`), reverts to `.accessory` (`:293`), opens
the main window (`:294`). The first-run gate at `:198-202` is skipped in test
mode (`isTestMode`, `:196-197`), so no XCUITest can drive the first-run window.

`MenuBarController` already conforms to `NSWindowDelegate` (its
`windowWillClose(_:)` at `:313-330` uses the `nonisolated func … { Task {
@MainActor in … } }` pattern) but is the delegate for the main/settings windows
only; the onboarding window is AppDelegate's and has no delegate. Menu items
currently reach AppDelegate behavior via `NotificationCenter` (`.openSettings`
/`.openWindow` observed at `MenuBarController.swift:115-124`).

**Onboarding source scan (row 7).** `scanSources()` (`OnboardingView.swift:219-250`)
holds 15 `(id, label, relativePath)` tuples (`:223-239`), filters archived
sources with `.filter { !ArchivedDefaultOffSources.contains($0.id) }` (`:241`),
and `fileExists` on each. Windsurf's tuple is `("windsurf", "Windsurf",
".codeium/windsurf")` (`:228`) — the **only** genuine drift; every other tuple
matches `SourceCatalog` (`SourceCatalog.swift:26-44`), `minimax` piggybacks on
the `claude-code` path (`:29`, same `~/.claude/projects`), and `lobsterai` is
correctly absent (test-enforced, below). `ForEach(0..<4)` step dots (`:16`) and
the `case 0/1/2/default` body switch (`:28-33`, `default` == readyStep) define
the 4-step flow.

**Test guards on row-7 surfaces.** `SourcesSyncTests.swift:90-94` asserts
`OnboardingView.swift` contains `!ArchivedDefaultOffSources.contains($0.id)` and
does NOT contain `("lobsterai"`. `:64-74` asserts `SourcesSettingsSection.swift`
has no `"path.` substring, no `UserDefaults.standard.string(forKey:` / `.set(`,
and keeps `read-only` / `Archived` / `configureClaudeCodeProfiles`.
`HomePopoverActionsTests.swift:195-198` asserts the menu-bar source never
contains `openWebUI`. These box any edit; none blocks the planned changes.

**MCP helper path derivation (row 7 slice).** `MCPSetupGuideView.helperPath` is
`@AppStorage("mcpHelperPath")` defaulting to the hardcoded
`/Applications/Engram.app/Contents/Helpers/EngramMCP` (`SourcesSettingsSection.swift:544`),
repeated as the `TextField` placeholder (`:597`); the Node sentence is at `:606`.
A dynamic resolver already exists and is compiled into the app target:
`EngramCLIContextCommand.mcpHelperCandidates(explicit:executablePath:environment:)`
(`macos/Shared/Service/EngramCLIContextCommand.swift:129-161`) builds
`{executableDir}/EngramMCP` → `{executableDir}/../Helpers/EngramMCP` →
`/Applications/…` (hardcoded 3rd fallback), honoring `ENGRAM_CLI_MCP_HELPER` /
`ENGRAM_MCP_PATH` overrides. `macos/Shared` is a source path of the `Engram`
app target (`project.yml`), so it is in the app binary. The `@AppStorage` key
`mcpHelperPath` is referenced only in this file.

**Feedback affordances (row 17).** None. `setupMainMenu()`
(`MenuBarController.swift:505-560`) builds App/Edit/View/Window and sets
`NSApp.mainMenu` (`:559`); `NSApp.helpMenu` is never set. `setupMainMenu()` runs
only in window mode (`openSettings` `:211`, `openWindow` `:302`); the
menu-bar-only path uses `showContextMenu()` (`:176-197`: Open Window / Settings /
Quit, with `menuDidClose` nil-ing `statusItem.menu` at `:200-202`). The app
version is `Bundle.main` `CFBundleShortVersionString` (`AboutSettingsSection.swift:25`);
the diagnostics export button is at `:35-41`.

**MCP mention + "configured" detection (row 24).** Zero MCP mentions in
onboarding. Nothing in the app reads any MCP client config: `grep` for
`.claude.json` / `.mcp.json` / `mcpServers` / `claude_desktop_config` across
`macos/Engram` hits only a display-only hint string `"~/.claude.json or: claude
mcp add"` (`SourcesSettingsSection.swift:553`). **The gate is buildable from
disk**: the app is **not sandboxed** (`macos/Engram/Engram.entitlements:5`, "No
app sandbox — developer tool needs filesystem access"), so plain `FileManager`
reads home-root config files (`~/.claude.json` is not under TCC-protected
`~/Library`, so no Full Disk Access is required — the onboarding FDA step
`OnboardingView.swift:130-165` is only for `~/Library` sources). Verified on
this machine: `~/.claude.json` (0600) carries a global `mcpServers.engram` entry
`{command,args,env,type:"stdio"}`; the plugin's `.mcp.json`
(`integrations/claude-code/engram/.mcp.json`) declares the same server under key
`engram` pointing at a wrapper script. Plugin-install markers are **unreliable**:
`~/.claude/plugins/installed_plugins.json` does not mention engram for an
inline/dev enable, and `~/.claude/plugins/data/engram-inline/` is an empty
marker dir. Claude *Desktop* config
(`~/Library/Application Support/Claude/claude_desktop_config.json`) is a
separate file that did **not** contain engram. The `>0 sessions` half of the
gate is already in HomeView scope: `serviceStatusStore.totalSessions`
(`EngramServiceStatusStore.swift:39`, drives the `.task` id at `HomeView.swift:46`)
and `kpi.sessions` (`HomeView.swift:95`). The card slots into the body VStack
between `kpiSection` and `workbenchGrid` (`HomeView.swift:34-41`).

**MCP verification building blocks (row 28).** Rung 1 (resolve):
`mcpHelperCandidates` (above). Rung 2 (exec bit): `isExecutableFile(_:)` checks
`fileExists && !isDirectory && isExecutableFile` (`EngramCLIContextCommand.swift:163-168`).
Rung 3 (handshake): `invokeMCPGetContext(...)` (`:332-542`) spawns the helper,
sends `initialize` (id 1, protocolVersion 2025-11-25, `:361-373`) then
`notifications/initialized` + `tools/call` with `name: "get_context"`
(`:378-386`), and returns `MCPInvocationResult { text, timedOut, helperMissing,
malformed, processFailed }` (`:261-267`) — the exact failure taxonomy a ladder
needs. It is reachable through the injectable `MCPInvoker` typealias
(`:269-275`) and `defaultMCPInvoker` seam (`:316-330`). The helper *does* answer
`tools/list` (`macos/EngramMCP/Core/MCPStdioServer.swift:137`), but
`invokeMCPGetContext` issues `tools/call get_context`, not `tools/list` (mirror
correction). Rung 4 (socket): `EngramServiceStatusStore.isRunning`
(`EngramServiceStatusStore.swift:60-63`) / `serviceClient.status()`
(`AboutSettingsSection.swift:111`), both already in the Settings environment.

## Proposed design

Four independent parts. A reader implementing one part can ignore the other
three. Each part is the minimum that meets its goal.

---

### Part A — Onboarding first-run correctness (row 7)

Four surgical fixes, all in `App.swift`, `OnboardingView.swift`,
`SourcesSettingsSection.swift`.

**A1. Record completion on window close.** Make `AppDelegate` conform to
`NSWindowDelegate`. In `showOnboarding()` set `win.delegate = self` (after
`:277`). Route the button and the close through **one** completion path to
eliminate the double-fire hazard: keep `completeOnboarding()` as the single
recording function and call it from `windowWillClose`.

```swift
// AppDelegate, mirroring MenuBarController.windowWillClose (:313)
nonisolated func windowWillClose(_ notification: Notification) {
    Task { @MainActor in
        guard (notification.object as? NSWindow) === self.onboardingWindow else { return }
        self.completeOnboarding()   // idempotent; see guard below
    }
}
```

Re-entrancy: `completeOnboarding()` calls `onboardingWindow?.close()` (`:289`),
which re-fires `windowWillClose`. Guard by nil-ing the delegate **before** the
close, at the top of `completeOnboarding()`:

```swift
private func completeOnboarding() {
    onboardingWindow?.delegate = nil          // stop the close→delegate re-entry
    UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
    onboardingWindow?.close()
    onboardingWindow = nil
    NSApp.setActivationPolicy(.accessory)
    menuBarController?.openWindow()
}
```

Now every dismissal — button, red close button, `Cmd-W` — records completion and
reverts activation policy exactly once. The button's `onComplete` closure is
unchanged (it still calls `completeOnboarding`).

**A2. Windsurf probe path.** `OnboardingView.swift:228` → change the relative
path from `.codeium/windsurf` to `.engram/cache/windsurf` so the probe matches
`SourceCatalog.swift:41`. Preserve the `!ArchivedDefaultOffSources.contains`
filter (`:241`) and add no `lobsterai` tuple (test-enforced).

**A3. Derive the MCP helper path.** In `MCPSetupGuideView`, replace the
hardcoded `@AppStorage` default with a computed default derived from the running
bundle via the existing resolver, called with the app's own executable path.
Change the property (`SourcesSettingsSection.swift:544`) from the `/Applications/…`
string literal to `Self.defaultHelperPath()`:

```swift
@AppStorage("mcpHelperPath") var helperPath: String = Self.defaultHelperPath()

static func defaultHelperPath() -> String {
    EngramCLIContextCommand.mcpHelperCandidates(
        explicit: nil,
        executablePath: Bundle.main.executableURL?.path ?? CommandLine.arguments.first ?? "",
        environment: ProcessInfo.processInfo.environment
    ).first(where: EngramCLIContextCommand.isExecutableFile)
    ?? EngramCLIContextCommand.mcpHelperCandidates(explicit: nil, executablePath: Bundle.main.executableURL?.path ?? "", environment: [:]).first
    ?? "/Applications/Engram.app/Contents/Helpers/EngramMCP"
}
```

Blast-radius note: `@AppStorage` returns the **persisted** value over a changed
default once written, so the new default helps fresh installs immediately but a
user who already stored the stale `/Applications/…` literal keeps it. Migrate
those users by seeding once from `.onAppear`, operating on the `@AppStorage`
`helperPath` **binding property** — never on raw `UserDefaults`:

```swift
.onAppear {
    if helperPath == "/Applications/Engram.app/Contents/Helpers/EngramMCP" {
        helperPath = Self.defaultHelperPath()   // binding assignment, guard-safe
    }
}
```

This is naturally idempotent (once replaced, the equality no longer matches) and
needs no separate first-render flag. A fresh user already resolves correctly via
the changed default, so no nil check is needed. Because the seed reads the
`helperPath` property and assigns through the `@AppStorage` binding — not
`UserDefaults.standard.string(forKey:` (forbidden by `SourcesSyncTests.swift:71`,
a *read* guard) and not `UserDefaults.standard.set(` (forbidden by `:72`, a
*write* guard) — neither forbidden substring appears in this file, so
`testSourcesSettingsHasNoDeadPathKeysAndKeepsCatalogReadOnly` stays green.

**A4. Delete the Node sentence.** Remove `SourcesSettingsSection.swift:606-609`
(the `Text("Node MCP and daemon HTTP settings are legacy rollback paths…")` and
its modifiers). It is the only Node-MCP reference in the view.

**Implementation slices (A):**
- A-1: A1 (delegate + completion unification) + repro test. Independently
  landable.
- A-2: A2 (Windsurf path) + source guard. Independently landable.
- A-3: A3 + A4 (helper derivation, Node sentence) + source guards. Independently
  landable.

**Acceptance criteria (A):**
1. Fresh `UserDefaults(suiteName:)`; after the onboarding-close completion path
   runs (button *or* window close), `hasCompletedOnboarding == true` and
   `NSApp.activationPolicy() == .accessory`. Falsifiable via the extracted
   completion seam (Test plan).
2. `windowWillClose` fires the completion path exactly once when
   `completeOnboarding()` closes the window (no double `openWindow`).
3. `OnboardingView.swift` contains `.engram/cache/windsurf` and not
   `.codeium/windsurf`; still contains `!ArchivedDefaultOffSources.contains($0.id)`
   and not `("lobsterai"`.
4. `SourcesSettingsSection.swift` contains `mcpHelperCandidates(` and
   `Bundle.main`; does not contain `Node MCP`; still passes
   `SourcesSyncTests.testSourcesSettingsHasNoDeadPathKeysAndKeepsCatalogReadOnly`.

---

### Part B — Give the app a mouth (row 17)

**B1. Help menu (window mode).** In `setupMainMenu()`
(`MenuBarController.swift:505-560`), after the Window menu is appended (`:556`)
and before `NSApp.mainMenu = mainMenu` (`:559`), append a Help submenu and set
`NSApp.helpMenu` so macOS renders the Help search field:

```swift
let helpMenu = NSMenu(title: String(localized: "Help"))
let reportItem = NSMenuItem(title: String(localized: "Report an Issue…"),
    action: #selector(reportAnIssue), keyEquivalent: "")
reportItem.target = self
helpMenu.addItem(reportItem)
let onboardItem = NSMenuItem(title: String(localized: "Show Onboarding"),
    action: #selector(showOnboardingFromMenu), keyEquivalent: "")
onboardItem.target = self
helpMenu.addItem(onboardItem)
let helpMenuItem = NSMenuItem(); helpMenuItem.submenu = helpMenu
mainMenu.addItem(helpMenuItem)
NSApp.helpMenu = helpMenu
```

**B2. Menu-bar-only reachability.** The main menu bar is invisible in accessory
mode. Add the same two items to `showContextMenu()`
(`MenuBarController.swift:176-197`) as plain items before the separator (`:187`),
preserving the `menu.delegate = self` / `statusItem.menu` / `menuDidClose` swap
(`:194-202`). This keeps left-click→popover intact.

> **Collision (integration pass, 2026-07-25) — `showContextMenu()` is also edited
> by `docs/service-resilience-design-2026-07.md` Part A (row 5)**, which inserts a
> conditional "Restart Service" item gated on `serviceStatusStore.isFailed`
> *before Quit* (after the separator). The two edits are additive: these Help
> items go *before the separator*, the Restart item *after* it. Whichever lands
> second must merge into the one menu build. Agreed order top-to-bottom: Open
> Window / Settings / (Report an Issue, Show Onboarding) / separator / [Restart
> Service when `isFailed`] / Quit — see the reciprocal note in the row-5 spec.

**B3. Report action.** A pure URL builder (unit-testable):

```swift
enum GitHubIssueURL {
    static let repo = "https://github.com/bbingz/engram"   // from plugin.json homepage
    static func reportIssue(version: String, build: String) -> URL {
        var c = URLComponents(string: "\(repo)/issues/new")!
        c.queryItems = [
            .init(name: "title", value: "[Report] "),
            .init(name: "body", value: "Version: \(version) (\(build))\n\n"),
        ]
        return c.url!
    }
}
```

`reportAnIssue` reads version from `Bundle.main` `CFBundleShortVersionString`
and build from `CFBundleVersion`, builds the URL, and `NSWorkspace.shared.open`s
it. `showOnboardingFromMenu` posts a new `.showOnboarding` notification observed
by `AppDelegate` (the established idiom; `AppDelegate.showOnboarding` is private,
so route through `NotificationCenter`, not a direct call — see Part A/D wiring).
AppDelegate observes `.showOnboarding` and calls `showOnboarding()`.

**B4. Attach-to-issue affordance.** Beside the existing diagnostics Export button
(`AboutSettingsSection.swift:35-41`), add a caption line: after export, show
"Attach the saved file to a GitHub issue" with a link to
`GitHubIssueURL.reportIssue`. No upload; reuses the on-disk bundle.

**Implementation slices (B):**
- B-1: B3 (URL builder) + unit test. Pure, independently landable, no UI.
- B-2: B1 + B2 (Help menu + context-menu items) + source guards. **Depends on
  B-1** (consumes `GitHubIssueURL`); land after it. Done-when: `MenuBarController.swift`
  contains `NSApp.helpMenu` + the two item titles.
- B-3: B4 (About attach copy) + source guard. Independently landable (links to
  `GitHubIssueURL`, so land after B-1).

**Acceptance criteria (B):**
1. `GitHubIssueURL.reportIssue(version: "1.0.5", build: "42")` returns a URL whose
   host is `github.com`, path ends `/issues/new`, and whose `body` query item
   contains `1.0.5` and `42`. Falsifiable unit assertion.
2. `MenuBarController.swift` source contains `NSApp.helpMenu`, `Report an Issue`,
   and `Show Onboarding`; still contains no `openWebUI`
   (`HomePopoverActionsTests:195-198`).
3. `showContextMenu()` region contains the two Help items; `menuDidClose` reset
   is unchanged.
4. `AboutSettingsSection.swift` contains the attach-to-issue link copy.

---

### Part C — MCP activation card (row 24)

**C1. Detector.** A pure function reading Claude Code config, scoped to Claude
Code only (the most reliable single signal; breadth deferred to Non-goals):

```swift
enum MCPClientDetection {
    /// True iff any mcpServers map (global or per-project) has a key named
    /// exactly "engram". Matches on the KEY, never the command path, so the
    /// direct-add, plugin-wrapper, and ~/.engram/bin variants all count.
    static func isEngramConfigured(claudeJSON data: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        if let global = root["mcpServers"] as? [String: Any], global["engram"] != nil {
            return true
        }
        if let projects = root["projects"] as? [String: Any] {
            for case let proj as [String: Any] in projects.values {
                if let m = proj["mcpServers"] as? [String: Any], m["engram"] != nil {
                    return true
                }
            }
        }
        return false
    }
    /// Reads ~/.claude.json off-main; returns false if absent/unreadable.
    static func isEngramConfiguredOnDisk() -> Bool {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: path) else { return false }
        return isEngramConfigured(claudeJSON: data)
    }
}
```

Do **not** key on plugin-install markers (Current state: unreliable). Do **not**
read Claude Desktop config.

**C2. Gate.** A pure, non-private predicate (following the `todayPanelRowLimit`
testability precedent, `HomeView.swift:4-7`):

```swift
enum MCPActivationGate {
    static func shouldShow(indexedSessions: Int, mcpConfigured: Bool, dismissed: Bool) -> Bool {
        indexedSessions > 0 && !mcpConfigured && !dismissed
    }
}
```

`indexedSessions` = `serviceStatusStore.totalSessions` (or `kpi.sessions`).
`mcpConfigured` = detector result, computed **off-main in `HomeView.loadData`'s
`Task.detached` block** (`HomeView.swift:354-379`) into a `@State var mcpConfigured`
— never in the view body — so a ~330 KB JSON parse never blocks a render. Gate
the read on the current state: `loadData` fires on **every** index tick (the
`.task(id:)` keyed on `totalSessions`, `HomeView.swift:46`), so run the detector
only while `!mcpConfigured` — once it flips true the card is suppressed for the
session and the disk read stops (it does not re-parse `~/.claude.json` on every
subsequent tick). `dismissed` = `@AppStorage("mcp.activationCardDismissed")`
(dotted-namespace precedent).

**C3. Card.** A new `@ViewBuilder` inserted in the body VStack between
`kpiSection` and `workbenchGrid` (`HomeView.swift:34-41`), gated on
`MCPActivationGate.shouldShow(...)`, carrying `accessibilityIdentifier
"home_mcpActivationCard"`. Copy names MCP explicitly and one sentence on the
tools: *"Engram is a memory layer for AI coding tools. Connect it over MCP to
give Claude `get_context`, `search`, and `save_insight` across your past
sessions."* Two actions: a primary "Set up MCP" that opens Settings → Data
Sources (`MCPSetupGuideView`) — **not** a silent install; and a dismiss "×" that
sets the `@AppStorage` flag. Rationale for explain-then-act (not one-tap
install): the card must not write client config on the user's behalf, mirroring
`as-main`'s QuotaMeterPromoView (explainer AND consent because the action cannot
be silent).

**C4. Onboarding MCP step.** Add a 5th step naming MCP, inserted **between Full
Disk Access (step 2) and Ready** — so MCP becomes step 3 and Ready moves to step
4. This is not a pure append, but with that insertion position **none** of the
existing `advance(to:)` numerals change; the exact edits are:
- `ForEach(0..<4)` (`OnboardingView.swift:16`) → `ForEach(0..<5)`.
- Switch (`:28-33`): keep `case 0/1/2`, add `case 3: mcpStep`, and move
  `readyStep` from `default` to `case 4:` (`default` no longer maps to
  `readyStep`; use an explicit case so the two-value `default` bug can't recur).
- FDA's `advance(to: 3)` (`:156`) is **unchanged** — it now lands on the new MCP
  step. `advance(to: 1)` (`:61`) and `advance(to: 2)` (`:117`) are unchanged.
- The new `mcpStep` Continue button adds `advance(to: 4)` to reach Ready.

The MCP step is copy-only (icon + one paragraph + Continue); it reads no config
and gates nothing.

**Implementation slices (C):**
- C-1: C1 + C2 (detector + gate) + unit tests. Pure, no UI, independently
  landable.
- C-2: C3 (HomeView card, wired to C1/C2 off-main) + source + gate tests.
  **Depends on C-1** (consumes the detector + gate); land after it. Done-when:
  `HomeView.swift` contains `home_mcpActivationCard` and the detector call in
  `loadData`.
- C-3: C4 (onboarding MCP step + insertion edits). Independently landable
  (touches only `OnboardingView.swift`).

**Acceptance criteria (C):**
1. `isEngramConfigured` returns true for JSON with global `mcpServers.engram`,
   true for `projects.<p>.mcpServers.engram`, false for a config with only other
   servers, false for empty/garbage data. Falsifiable unit assertions with
   fixture JSON strings.
2. `MCPActivationGate.shouldShow`: true only when
   `indexedSessions>0 && !mcpConfigured && !dismissed`; all other combinations
   false. Truth-table unit test.
3. `HomeView.swift` source contains `home_mcpActivationCard`, `MCPActivationGate`,
   `get_context`, `search`, `save_insight`, and computes `mcpConfigured` inside
   the `Task.detached` block (asserted by the detector call appearing in
   `loadData`, not the body).
4. `OnboardingView.swift` contains `MCP` and `ForEach(0..<5)`; the body switch
   has an explicit non-default MCP case; `readyStep` is still reachable.

---

### Part D — Verify MCP setup in-app (row 28)

**D1. Rung ladder.** A pure type driving injected closures, so each rung is unit
tested without spawning a subprocess:

```swift
enum MCPVerifyRung: Equatable { case resolve, execBit, handshake, socket }

struct MCPVerifyResult: Equatable {
    let passed: Bool
    let failingRung: MCPVerifyRung?     // nil when passed
    let remedy: String?                 // nil when passed
    let resolvedPath: String?
}

enum MCPVerificationLadder {
    static func verify(
        candidates: [String],
        isExecutable: (String) -> Bool,
        invoke: (String) -> EngramCLIContextCommand.MCPInvocationResult,
        serviceRunning: Bool
    ) -> MCPVerifyResult {
        // Rung 1: resolve — a candidate that exists ON DISK. Note the production
        // invoker feeds `EngramCLIContextCommand.mcpHelperCandidates(...)`, which
        // is NEVER empty (it always appends the hardcoded
        // `/Applications/Engram.app/Contents/Helpers/EngramMCP` third fallback,
        // EngramCLIContextCommand.swift:157). So there is no `?? candidates.first`
        // fallback: if no candidate FILE exists, `.resolve` must fire — otherwise
        // a missing helper leaks into rung 2 and is misreported as `.execBit`
        // with a chmod remedy on a file that does not exist.
        guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            return .init(passed: false, failingRung: .resolve,
                remedy: "Engram MCP helper not found. Install Engram.app or set ENGRAM_MCP_PATH.",
                resolvedPath: nil)
        }
        // Rung 2: exec bit.
        guard isExecutable(path) else {
            return .init(passed: false, failingRung: .execBit,
                remedy: "Helper found but not executable. Re-download Engram.app, or run: chmod +x \(path)",
                resolvedPath: path)
        }
        // Rung 3: live handshake — reuse invokeMCPGetContext's failure taxonomy.
        let r = invoke(path)
        if r.helperMissing {
            return .init(passed: false, failingRung: .handshake,
                remedy: "Helper disappeared mid-launch. Re-download Engram.app.", resolvedPath: path)
        }
        if r.processFailed {
            return .init(passed: false, failingRung: .handshake,
                remedy: "Helper crashed on launch. Check Console for com.engram logs.", resolvedPath: path)
        }
        if r.timedOut {
            return .init(passed: false, failingRung: .handshake,
                remedy: "MCP handshake timed out. Ensure the Engram service is running.", resolvedPath: path)
        }
        if r.malformed {
            return .init(passed: false, failingRung: .handshake,
                remedy: "Unexpected MCP response. Update Engram to match your MCP client.", resolvedPath: path)
        }
        // Rung 4: service socket — mutating tools (save_insight) fail closed without it.
        guard serviceRunning else {
            return .init(passed: false, failingRung: .socket,
                remedy: "Handshake works but the Engram service is down; save_insight will fail. Start Engram or use the menu-bar Restart.",
                resolvedPath: path)
        }
        return .init(passed: true, failingRung: nil, remedy: nil, resolvedPath: path)
    }
}
```

Rung 3 reuses `invokeMCPGetContext` verbatim through the injected `invoke`
closure (production wiring passes `{ EngramCLIContextCommand.invokeMCPGetContext(
helperPath: $0, cwd: FileManager…currentDirectoryPath, task: nil, maxTokens:
256, timeoutMs: 5000) }`). A well-formed response — even an *empty* context —
means initialize + tool dispatch worked, which is the liveness signal; the four
failure bools are the only rejection conditions. Rung 4 reads
`serviceStatusStore.isRunning`.

**D2. UI.** Replace the passive `PathExistsIndicator(path:)` call at
`SourcesSettingsSection.swift:600` with a "Test now" button + a 3-state result
(untested / testing / result), mirroring `as-main`'s user-initiated
`performTest` (`as-main/AgentSessions/Preferences/PreferencesView+Usage.swift:544-547,590,658-661`).
On tap, run `MCPVerificationLadder.verify` off-main; render pass (green + "MCP
setup verified") or the first failing rung's one remedy line (red). **Never on a
timer, never on render** — the button is the only trigger, because rung 3 spawns
a real subprocess. `PathExistsIndicator` stays available for other callers but is
no longer the MCP verifier.

**Implementation slices (D):**
- D-1: D1 (ladder type) + unit tests per rung. Pure, no UI, independently
  landable.
- D-2: D2 (Test-now button + result, with the real invoker) + source guard.
  **Depends on D-1** (consumes `MCPVerificationLadder`); land after it. Done-when:
  `SourcesSettingsSection.swift` contains `MCPVerificationLadder` + a "Test now"
  trigger, with no `.task`/`onAppear` invoking verify.

**Acceptance criteria (D):**
1. `verify` returns `.resolve` when no candidate path exists **on disk** —
   including the production shape where `candidates` is non-empty but every entry
   (e.g. the hardcoded `/Applications/…` fallback) is absent from disk; `.execBit`
   when a candidate exists on disk but is non-executable; `.handshake` for each of
   helperMissing/processFailed/timedOut/malformed (distinct remedies);
   `.socket` when the handshake passes but `serviceRunning == false`;
   `passed == true` only when all four rungs pass. Falsifiable per-rung unit
   assertions with injected closures — no subprocess.
2. Each failing result carries exactly one non-nil `remedy` naming the specific
   fix; `passed` results carry nil remedy.
3. `SourcesSettingsSection.swift` source contains a "Test now" trigger and
   `MCPVerificationLadder`; the verify runs only from the button action (no
   `.task`/`onAppear` invoking it).

## Invariants affected

**None.** Stated explicitly per the ledger requirement:

- **#1 / #12 Single-Writer / EngramMCP read-only** (`docs/invariants.md:5-10`,
  `:82-87`) — **not touched**. This spec adds no SQLite writer. Part D's rung-3
  handshake is the pre-existing read-only `initialize` + `tools/call get_context`
  (`EngramCLIContextCommand.swift:332-542`); it opens no new writer and reuses
  code already in the app binary. The MCP output schemas'
  `additionalProperties:false, required:["content"]` constraint
  (`macos/EngramMCP/Core/MCPOutputSchemas.swift`) is respected because
  verification parses raw JSON-RPC app-side and adds no MCP tool or response
  field.
- **#2 / #3 Subagent Skip / Tier Visibility** (`:12-24`) — **not touched**. No
  tiering, no `sessions` write, no FTS delta.
- **#9 Startup Backfills** (`:61-66`) — **not touched**. No new backfill; the
  ledger's forward-references here belong to the concurrent
  `codex-native-parentage` spec, not this one.
- **#11 / #13 Schema / Tail Checkpoints** (`:75-80`, `:89-94`) — **not touched**.
  No column, no `file_index_state` write.

`docs/invariants.md` is read-only for this spec: no entry is amended, no gate in
`scripts/invariant-gates.json` applies. `scripts/check-invariants-ledger.sh`
need not change. (The concurrent baseline specs amend entries 2/3/9/10; this
spec composes by leaving them alone.)

## Alternatives considered

- **Row 7: detect fresh install by DB/artifact absence.** Lost — the app opens
  `~/.engram/index.sqlite` at `App.swift:122` (`db.open()`) before the gate at
  `:199` (service start is at `:131`, guarded at `:127`; `EngramServiceRunner.swift:122-127`
  only builds the DB path string). The file exists by gate-time; unreliable.
  Keep the UserDefaults flag.
- **Row 7: give each menu item a direct call to `AppDelegate.showOnboarding`.**
  Lost — it is `private` and menu items target `MenuBarController`. Use the
  `.showOnboarding` notification idiom (matches `.openSettings`/`.openWindow`).
- **Row 24: gate the card on plugin-install markers** (`installed_plugins.json`
  / `plugins/data/engram-inline`). Lost — an inline/dev enable leaves no engram
  entry there and the marker dir is empty, so already-configured users would be
  nagged. Gate on `mcpServers.engram` in `~/.claude.json` instead — that is what
  actually determines whether tools resolve.
- **Row 24: match the MCP server by command path.** Lost — the command differs
  across direct-add (`/Applications/…/EngramMCP`), plugin wrapper
  (`${CLAUDE_PLUGIN_ROOT}/scripts/engram-mcp`), and `~/.engram/bin/engram-mcp`.
  Match the **key** `engram` only.
- **Row 24: detect gemini/codex/cursor configs too.** Deferred (Non-goals).
  Gemini/Cursor are JSON but Codex is TOML (`~/.codex/config.toml` `[mcp_servers.engram]`)
  and Foundation has no TOML parser; the extra breadth is not worth a hand-rolled
  TOML read for the first landing. Claude Code is the plugin's target.
- **Row 28: verify with `initialize` + `tools/list` instead of `get_context`.**
  Cleaner (no cwd, no DB read, deterministic tool-name list, could even assert
  the three tool names are present) but requires generalizing `invokeMCPGetContext`
  to issue `tools/list` as id 2. Deferred as a refinement — reusing
  `invokeMCPGetContext` verbatim is the minimum that yields the four-way failure
  taxonomy the ladder needs, and an empty-but-well-formed `get_context` response
  is a sufficient liveness signal. If the get_context cwd/DB dependency proves
  noisy in practice, switch to `tools/list` (open question).
- **Row 28: reuse `PathExistsIndicator` and just add exec-bit.** Lost — the
  point of the row is a *ladder* that distinguishes a dead socket from a missing
  binary; a richer indicator without the handshake still gives a green dot on a
  crashing helper.
- **Row 17: upload diagnostics from the app.** Cut (Non-goals). "Attach the
  saved file to a GitHub issue" copy + the existing on-disk export is the
  minimum that closes the loop without a backend.

## Test plan

All Swift; SwiftUI bodies are not unit-instantiable here, so behavior lives in
pure helpers (unit-tested) and view wiring is pinned by source-substring guards,
matching `HomePopoverActionsTests` / `SourcesSyncTests`.

**Part A (`macos/EngramTests/`).**
- Repro (bug fix, `_repro`): the bug is that closing the onboarding window never
  records completion because `AppDelegate` is not an `NSWindowDelegate` and the
  onboarding window has no delegate (`App.swift:262-285`). The completion path
  cannot be unit-instantiated — the first-run gate is skipped in test mode
  (`App.swift:196-198`) and `showOnboarding`/`completeOnboarding` are `private`
  (`:262,:287`), so no injectable window-close harness exists. Rather than ship a
  tautological seam that always sets the flag (green the moment it is written,
  regardless of whether the close is ever wired), the `_repro` is the **source
  guard** on the wiring itself, which is genuinely red-before / green-after A1.
  In `HomePopoverActionsTests.swift`:
  ```swift
  // docs/mcp-activation-onboarding-design-2026-07.md — mirror row 7.
  func testAppDelegateWiresOnboardingWindowClose_repro() throws
  ```
  Assert `App.swift` source contains `NSWindowDelegate` and a `windowWillClose(_:)`
  that references `onboardingWindow`. Red on `main` (App.swift has neither); green
  after A1 adds the delegate conformance and the close handler. Record the
  red→green transition in the PR.
- Source guards in `SourcesSyncTests.swift` (extend the existing file):
  `OnboardingView.swift` contains `.engram/cache/windsurf`, not
  `.codeium/windsurf`, still has the archived filter and no `("lobsterai"`;
  `SourcesSettingsSection.swift` contains `mcpHelperCandidates(` and `Bundle.main`,
  not `Node MCP`, and still passes the existing dead-path-key guards.
- Regression guard in `HomePopoverActionsTests.swift`: the menu-bar source still
  contains no `openWebUI` (the `_repro` above covers the `NSWindowDelegate` /
  `windowWillClose` wiring).

**Part B (`macos/EngramTests/`).**
- Unit (new `GitHubIssueURLTests.swift`): `reportIssue(version:build:)` host,
  path, and body-query assertions.
- Source guards in `HomePopoverActionsTests.swift`: `MenuBarController.swift`
  contains `NSApp.helpMenu`, `Report an Issue`, `Show Onboarding`, and the
  context-menu variants; `AboutSettingsSection.swift` contains the attach copy.

**Part C (`macos/EngramTests/`).**
- Unit (new `MCPClientDetectionTests.swift`): `isEngramConfigured` over four
  fixture JSON strings (global hit, per-project hit, other-servers-only miss,
  garbage miss).
- Unit (new `MCPActivationGateTests.swift`): the 8-row truth table for
  `shouldShow`.
- Source guards in `HomePopoverActionsTests.swift`: `HomeView.swift` contains
  `home_mcpActivationCard`, `MCPActivationGate`, the three tool names, and the
  detector call inside `loadData`; `OnboardingView.swift` contains `MCP` and
  `ForEach(0..<5)`.

**Part D (`macos/EngramTests/`).**
- Unit (extend `EngramCLIContextCommandTests.swift` or new
  `MCPVerificationLadderTests.swift`): one test per rung outcome
  (`testVerifyReportsResolveWhenNoCandidateExistsOnDisk` — passing a **non-empty**
  list of paths that do not exist on disk (the production shape), asserting
  `.resolve`, not `.execBit`; `…ExecBitWhenNotExecutable`, `…HandshakeTimeout`,
  `…HandshakeProcessFailed`, `…HandshakeMalformed`, `…SocketDownAfterHandshake`,
  `…PassesWhenAllRungsPass`), each with injected `isExecutable` / `invoke` /
  `serviceRunning` — no subprocess.
- Source guard: `SourcesSettingsSection.swift` contains `MCPVerificationLadder`
  and a "Test now" trigger, and does not invoke verify from `.task`/`onAppear`.

**Intentionally not tested:** the live subprocess spawn (covered by the existing
`invokeMCPGetContext` tests and the injected-closure ladder tests); TOML/Codex
config detection (out of scope); the exact HomeView JSON-read latency (asserted
only as "off-main in loadData", not timed).

## Rollout

No version bump, no migration, no schema change. Ships in the next `Engram.app`
build; `EngramService` is unaffected. All four parts are behavior-only UI/AppKit
changes plus read-only file/socket reads. Parts land independently in any order;
Part A's helper-derivation seed (A3) is the only stateful change and is a
one-time `@AppStorage` overwrite.

Revert story: each part is a self-contained set of view/menu edits plus one or
two pure helpers. Reverting a part removes its UI and its helper; no persisted
state needs cleanup except the `mcp.activationCardDismissed` key (inert if
orphaned) and the A3 helper-path seed (a user can retype the path). No data is
rewritten.

## Risks and open questions

- **Medium — Help menu invisible in accessory mode.** `setupMainMenu()` runs
  only in window mode (`MenuBarController.swift:211,302`). B2 mirrors the two
  items into `showContextMenu()` to cover menu-bar-only users; if that mirroring
  is skipped, Report-an-Issue/Show-Onboarding are unreachable until a window
  opens. Mitigated by B2; verify the context-menu items don't break the
  `menuDidClose` menu/popover swap (`:200-202`).
- **Medium — A3 `@AppStorage` shadowing.** The persisted `mcpHelperPath` value
  wins over the derived default for existing users, so A3 needs the one-time
  seed-overwrite. `SourcesSyncTests.swift` forbids **two** distinct substrings in
  this file: `:71` forbids the *read* `UserDefaults.standard.string(forKey:` and
  `:72` forbids the *write* `UserDefaults.standard.set(`. **Decided (not open):**
  the seed operates entirely on the `@AppStorage` `helperPath` property — property
  read for the equality check, binding assignment for the overwrite — so it emits
  neither forbidden substring. The default is changed to `Self.defaultHelperPath()`
  (fresh users resolve correctly with no nil check), and the equality guard
  (`helperPath == "/Applications/…"`) is idempotent. No raw `UserDefaults` access;
  the guard is not relaxed.
- **Medium — onboarding 5th-step insertion (C4).** Inserting a step is not a
  pure append: `default` currently *is* `readyStep` (`OnboardingView.swift:32`),
  so a naive insert that leaves `readyStep` on `default` renders it for two step
  values. With the chosen insertion (MCP between FDA and Ready → MCP = step 3,
  Ready = step 4), the existing `advance(to:)` numerals (`:61,117,156`) do **not**
  change — only a new `advance(to: 4)` is added and `readyStep` moves from
  `default` to `case 4`. Covered by the C4 acceptance criterion (explicit
  non-default MCP case), but this is still the likeliest regression — land C-3
  last and separately.
- **Low — reading ~330 KB `~/.claude.json` per detection.** Kept off-main in
  `HomeView.loadData`. Because `loadData` fires on every index tick
  (`.task(id:)` on `totalSessions`, `HomeView.swift:46`), C2 **gates** the
  detector on `!mcpConfigured`: it runs while the app is unconfigured and stops
  once the flag flips true, so it does not re-parse on every tick after
  configuration. The gate acts as a session-scoped cache of the positive result;
  accept unless profiling shows jank during the pre-configuration window.
- **Low — per-project-only engram config.** If `~/.claude.json` has
  `projects.<p>.mcpServers.engram` but no global entry, `isEngramConfigured`
  returns true (suppresses the card) even though a GUI app has no "current
  project" cwd. Accepted: any engram config means the user knows about MCP;
  over-suppressing is safer than nagging.
- **Open question — row 28 verifier: `get_context` vs `tools/list` for rung 3.**
  The minimum reuses `invokeMCPGetContext` (real cwd/DB read); a `tools/list`
  variant is cleaner and side-effect-free but needs a small generalization of
  that method. Decide during D-1 whether the get_context dependency is acceptable
  or worth the generalization. Left open; the ladder type is agnostic to which
  invoker is injected.
- **Open question — A1 delegate re-entrancy under AppKit.** The
  `delegate = nil`-before-`close()` guard is derived from the call graph, not
  from a run. Confirm on a build that `windowWillClose` fires exactly once for
  both the button and the red-close paths.
- **Open question — issue template query params.** `GitHubIssueURL` assumes
  `github.com/bbingz/engram/issues/new?title=&body=` accepts free-form
  `title`/`body`. If the repo adds an issue-form template, switch to
  `template=`/`labels=` params. Unverified against the live repo.
