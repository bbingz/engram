# Design Doc: Build Provenance and App-Process Perf Instrumentation

- **Status**: Draft
- **Owner**: unassigned
- **Date**: 2026-07-24
- **Related**: `docs/competitive-mirror-2026-07.md` backlog rows 15 (Q5) and 16
  (Q1). Composes beside the accepted baseline specs only at the invariants
  ledger (`docs/insight-supersede-filter-design-2026-07.md` appends entry 14 and
  `docs/publish-readiness-design-2026-07.md` appends entry 15; this spec appends
  entry **16** — the integration pass split the three claimants, see the
  collision note in Part A slice 4). No source-file overlap with the four
  concurrent baseline specs or the eight other mirror-follow-up specs.

Two engineering-hygiene rows, bundled because both harden local builds and
DEBUG diagnostics and neither ships product-user behavior. **Both are
publish-decision-independent** and do not couple to row 0. A reader
implementing only one row can ignore the other entirely: Part A touches only
`macos/scripts/*`, `macos/project.yml`, `tests/scripts/`, and the ledger; Part B
touches only `macos/Engram/Support/`, `macos/Engram/Views/`, `macos/Engram/App.swift`,
and `tests/scripts/`. They share no file.

Citations are verified against the working-tree HEAD `382693db` (branch
`feat/adapter-format-drift`, `git rev-list --count HEAD == 1341`). The brief's
nominal baseline `23dca547` is a different branch tip; the two scripts and views
cited here are not touched by the concurrent specs, so the anchors are stable,
but re-verify before implementing — the numbers will drift.

## Problem

**Row 15 — no bundle records which commit produced it.** `build-release.sh:76`
derives `CFBundleVersion` from `git rev-list --count HEAD` on a clean tree. On
`cb6bffc3` that count is 1340, matching installed `1.0.5` — but a count is a
*height*, not an identity: two different commits at the same height collide, and
a dirty local build falls back to a UTC timestamp (`build-release.sh:80`) with
**no commit reference at all**. `release-verify.sh` asserts hygiene, structure,
version-non-default, codesign, and notarization (`:77-164`) but never asserts
*which commit* the binary came from. The binary→commit binding is implicit,
undocumented, and unasserted. When a shipped build misbehaves, there is no
in-bundle field that names the source commit to diff against.

**Row 16 — the app process is uninstrumented.** `grep -rE
'os_signpost|OSSignpost|MetricKit|PerfSignpost' macos/` returns **zero** matches.
The service side is measured — `ServiceTelemetryCollector.swift` records
p50/p95/max/errorCount per IPC command, surfaced in `PerformanceView` and
`TraceExplorerView` — but that measures cross-socket service commands, not
app-local main-thread work. The unmeasured surface is the transcript and session
paging path: `SessionDetailView.parseWindow` (`:992`), `rebuildIndexed`
(`:1006`), and `SessionsPageView.loadData` (`:316`) / `loadMoreIfNeeded`
(`:449`). "Opening a big session feels slow" and "the list beachballs on scroll"
are today unquantified: no span timing, no main-thread stall signal.

## Goals / Non-goals

**Row 15**

- Goal: stamp the producing commit SHA and a dirty flag into the release bundle,
  injected **pre-archive** so it lives inside the signed seal.
- Goal: `release-verify.sh` asserts the stamp exists, is a 40-hex SHA, matches an
  expected value when given, and (for a distributable build) is clean.
- Goal: an opt-in `--require-ci-green` that reads (never writes) GitHub check-runs
  for HEAD's SHA and blocks the build unless the Tests workflow is green.
- Non-goal: tagging, pushing, publishing a GitHub release, adding secrets, or
  touching Homebrew/Sparkle. Enforced by `docs/TODO.md:31-33`; this spec only
  reads gh state and stamps a plist.
- Non-goal: a build-freshness TTL or a QA-run gate (as-main's model — see
  Alternatives). Engram CI-on-tag already gates the release commit; provenance,
  not expiry, is the gap.
- Non-goal: stamping the CI ad-hoc archive lane (`release.yml:150-162`). See
  Alternatives; scoped out to keep the change to the local build path.

**Row 16**

- Goal: an Instruments- and console-visible span timer plus an opt-in
  main-thread stall watchdog for the four paging sites, compiled **entirely out**
  of Release.
- Goal: DEBUG implementation and a signature-identical Release no-op ship in the
  **same commit** (the as-main `838c7396` lesson: unguarded spans broke Release).
- Non-goal: widening `.github/workflows/perf.yml` — it is a bespoke
  xctest-log parser around one `IndexerPerformanceTests` measure block
  (`perf.yml:50-101`) that cannot exercise app-UI signposts (no UI process).
- Non-goal: porting as-main's `PerfBench` self-driving harness
  (`as-main/AgentSessions/Support/PerfSignpost.swift:109-170`) — it depends on
  `AppWindowRouter` / `UnifiedSessionsView` / cockpit-mode that Engram lacks.
- Non-goal: extending `PerformanceView` / `TraceExplorerView`. Those poll service
  telemetry; PerfSignpost output goes to Instruments and the DEBUG console.

## Current state

Anchors verified at working-tree HEAD `382693db` on 2026-07-24.

### Row 15

**Build-number derivation (the implicit binding).** `build-release.sh:65-87`:
`BUILD_NUMBER` = `$ENGRAM_BUILD_NUMBER` if set, else — on a clean tree —
`git rev-list --count HEAD` (`:76`), else a UTC timestamp (`:80`). The dirty
detection is already computed at `:67-73`: `WORKTREE_DIRTY=1` unless `git diff`,
`git diff --cached`, and `git ls-files --others --exclude-standard` are all
empty. **`WORKTREE_DIRTY` and the clean-tree branch already exist** — Part A
reuses them and adds one `git rev-parse HEAD`. No new git plumbing.

**Injection mechanism (the `$(MARKETING_VERSION)` token pattern).**
`project.yml:208-209` maps `CFBundleShortVersionString` / `CFBundleVersion` to
build-setting tokens `$(MARKETING_VERSION)` / `$(CURRENT_PROJECT_VERSION)`;
`:222-223` defines those settings' defaults. `build-release.sh:106-113` passes
`MARKETING_VERSION=… CURRENT_PROJECT_VERSION="$BUILD_NUMBER"` on the `xcodebuild
archive` line, so xcodebuild substitutes them into Info.plist **at archive
time** — inside the signed seal. New provenance keys replicate this exactly.

**Why a post-export edit is illegal.** `release-verify.sh:129` runs
`codesign --verify --deep --strict` on the exported bundle. Info.plist is hashed
into `_CodeSignature/CodeResources`, so any PlistBuddy edit after signing breaks
the seal and fails `:129` — in both `--adhoc` and Developer-ID modes (`:129`
runs before the `--adhoc` early-exit at `:132-136`). Injection **must** be
pre-archive. `build-release.sh:117-128` already asserts the archived
`CFBundleVersion` equals the injected value; the provenance stamp copies that
assertion shape.

**What release-verify asserts today, and where the new clause slots.** Hygiene
`:77-93`; structure `:98-102`; version non-empty + unsubstituted-token rejection
`:112-119` (the `case … *'$('*` guard at `:117-119` checks **only** the two
version keys); optional `--expected-build` / `--expected-short-version` equality
`:121-126`; codesign `:129`; distribution-only Hardened-Runtime / Developer-ID /
timestamp `:141-155`; `--require-notarization` stapler+spctl `:157-164`. A
provenance clause slots after the version block (~`:126`) and mirrors the
optional `--expected-build` pattern.

**Test harness.** `tests/scripts/build-release-script.test.ts` builds a stub
`.app` (`buildStubApp` `:28-76`) and runs `release-verify.sh --adhoc` against it
(`runVerify` `:92-110`), plus script-text assertions on `build-release.sh`
(`:289-335`, e.g. "does not reuse the git commit count for dirty local release
builds" `:312-321`). This is the established TS-dev-tooling pattern for these
bash scripts, listed as invariant #7's verifier (`docs/invariants.md:51`).

**`--require-ci-green` target.** The only per-commit gate is `test.yml`
(`Tests`, on push/PR to main, `:3-7`). `release.yml` (`Release Gate`) fires only
on `v*` tags (`:13-16`), so on an untagged release HEAD it does not exist yet.
`gh` is at `/opt/homebrew/bin/gh`; remote is `github.com/bbingz/engram`.

**Nothing tags or publishes.** `build-release.sh` ends by *printing* manual
notarytool/stapler/DMG steps (`:194-227`); it never runs `git tag`, `gh
release`, or `push`. `release-verify.sh` is read-only.

### Row 16

**Baseline.** No `os_signpost` / `MetricKit` anywhere under `macos/`. Service
telemetry is `ServiceTelemetryCollector.swift` (IPC-granular, not app-local).
`macos/Engram/Support/` **does not exist**; the Engram target globs `- path:
Engram` recursively, so a new file under it auto-includes on `xcodegen generate`
with no `project.yml` sources edit.

**The four span sites — and what they actually measure.** All four push the
heavy work off-main via `Task.detached`:

- `SessionDetailView.parseWindow(offset:limit:)` (`:992-998`) →
  `MessageParser.parseWindowed`, `Task.detached(priority:.userInitiated)`
  (`:995`). Shared by `loadInitialTranscript` (`:1023-1031`) and `appendMessages`
  (`:1037-1046`), so instrumenting `parseWindow` covers every transcript-load
  path in one place. (The brief's `:1036` is a doc-comment line; the append body
  is `:1037-1046`.)
- `SessionDetailView.rebuildIndexed()` (`:1006-1019`) →
  `IndexedMessage.build`, `Task.detached` (`:1008`). Also shared by both paths.
- `SessionsPageView.loadData(preservePagination:)` (`:316-409`) → detached
  `db.listSessions` + stats + child counts (`:340-380`), main-actor apply
  `sessions = data.0` (`:387`).
- `SessionsPageView.loadMoreIfNeeded()` (`:449-509`) → detached page append
  (`:469-493`).

Because the work is `Task.detached`, a span around `await …value` measures
**async wall-clock latency** (actor hop + off-main compute), *not* a
main-thread block. That is the right signal for "why does opening/paging feel
slow", but it does not catch a beachball. The `MainThreadStallMonitor` is the
complementary instrument for the post-`await` main-actor apply and the SwiftUI
diff. **Part B states both signals explicitly** so the spans are not misread as
main-thread cost.

**as-main shape (verbatim,
`as-main/AgentSessions/Support/PerfSignpost.swift`).** `#if DEBUG enum Perf`:
`begin(_ name: StaticString, thresholdMs: Double = 16, _ detail: @escaping
@autoclosure () -> String = "") -> Span`, `end`, `event` — emitting
`os_signpost` intervals and a `print` only when `ms >= thresholdMs` (16ms = one
dropped frame); `detail` is lazily evaluated in `end()` (`:31-55`).
`MainThreadStallMonitor` (`:70-104`): `@MainActor` `.shared`, `DispatchSourceTimer`
on `.main` at 50ms interval / 200ms threshold; `start()` returns early unless an
env var is set (`:82-83`, as-main uses `AS_PERF_MONITOR`). **The `#else` Release
shim (`:171-186`) covers only `enum Perf`** — `MainThreadStallMonitor` and
`PerfBench` live *inside* `#if DEBUG` and have no Release twin.

**Env-name collision check.** `perf.yml:71` already sets `ENGRAM_PERF: "1"` to
enable the indexer perf path. The stall gate **must** be `ENGRAM_PERF_MONITOR`
(brief-specified); a shortened `ENGRAM_PERF` would silently couple to CI.

**Launch hook.** `App.swift:91` `applicationDidFinishLaunching(_:)` is the
one-time launch site where a DEBUG `MainThreadStallMonitor.shared.start()` call
belongs.

## Proposed design

Two independent parts. Each is the minimum that meets its goals.

---

### Part A — Build provenance (row 15)

**A1. Inject two keys pre-archive.** In `project.yml`, add under
`info.properties` (`:199-209`):

```yaml
EngramGitCommit: "$(ENGRAM_GIT_COMMIT)"
EngramGitDirty: "$(ENGRAM_GIT_DIRTY)"
```

and under the Engram target `settings` (`:210-223`) default values so a plain
`xcodebuild build` never emits a literal token:

```yaml
ENGRAM_GIT_COMMIT: "unknown"
ENGRAM_GIT_DIRTY: "1"
```

The `"unknown"` / `"1"` defaults are deliberately *non-distributable-looking*: an
un-overridden build reads as dirty/unknown, which the verifier rejects for a
distributable (A2). Reserved-key check: `EngramGitCommit` / `EngramGitDirty` are
not Apple-reserved Info.plist keys.

**A2. Compute and thread the values in `build-release.sh`.** In the existing
block that already computes `WORKTREE_DIRTY` (`:67-73`) and `BUILD_NUMBER`
(`:65-87`), add:

```bash
GIT_HEAD="$(git -C "$MACOS_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
GIT_DIRTY="$WORKTREE_DIRTY"   # already 0 (clean) or 1 (dirty) from :67-73
```

`git rev-parse HEAD` resolves on a dirty tree too, so a dirty local build still
carries its base commit (`GIT_DIRTY=1`). Then extend the archive command
(`:106-113`) with two settings, exactly as `CURRENT_PROJECT_VERSION` is passed:

```bash
  ENGRAM_GIT_COMMIT="$GIT_HEAD" \
  ENGRAM_GIT_DIRTY="$GIT_DIRTY"
```

`WORKTREE_DIRTY` is only assigned inside the `if [[ -z "$BUILD_NUMBER" ]]` branch
(`:66`); when `ENGRAM_BUILD_NUMBER` is set (CI path) it is never computed.
Move the `WORKTREE_DIRTY`/`GIT_HEAD` computation *above* that `if` so it is always
defined — a one-line hoist, not a new probe.

**A3. Verify in `release-verify.sh`.** After the version block (~`:126`), add a
provenance clause, gated to stay compatible with the existing stub tests (which
pass no provenance expectation):

- Extend the unsubstituted-token guard: read `EngramGitCommit` /
  `EngramGitDirty` via PlistBuddy; if either contains `$(`, fail (closes the
  `:117-119`-only-covers-version-keys gap the recon flagged).
- New optional flag `--expected-git-head <sha>`: when given, assert
  `EngramGitCommit == <sha>` and that it is 40-hex — mirroring `--expected-build`
  (`:121-123`), i.e. **before** codesign `:129`. On match, emit an
  `ok: git-head <sha>` line (mirroring the `ok version …` line at `:120`) so the
  positive path is observable in output. `build-release.sh:184` passes
  `--expected-git-head "$GIT_HEAD"` alongside `--expected-build`. **Harness note:**
  the stub `.app` fails `codesign --verify --deep --strict` (`:129`, its Helpers
  are not real Mach-O), so no stub run — `--adhoc` included — ever reaches the
  `:135` `exit 0`. The positive case is therefore asserted on the pre-signature
  `ok: git-head …` output substring (like the existing clean-stub test at
  `build-release-script.test.ts:132-138`), never on exit 0; a full green exit is
  validated only against a real signed bundle in CI / manual release runs.
- In the **distribution-only** block (non-`--adhoc`, after `:136`): assert
  `EngramGitDirty == "0"`; a dirty tree cannot produce a distributable, parallel
  to `build-release.sh:83-87` rejecting a default build number. Under `--adhoc`
  / `--local-only` a dirty stamp is allowed (local convenience builds). This
  clause sits **after** codesign `:129` alongside the Hardened-Runtime /
  Developer-ID / timestamp assertions (`:141-155`), which — per
  `build-release-script.test.ts:126-131` — are **not** stub-tested: a stub dies
  at codesign `:129` before reaching them. The dirty-distributable check inherits
  that same status: validated against a real bundle / CI, guarded in the harness
  only by a script-text assertion (Test plan), not a runtime stub run.

This keeps every existing stub test green: they run `--adhoc` with no
`--expected-git-head`, so the only new code they hit is the token guard, and a
stub with no provenance keys reads empty (skip).

**A4. `--require-ci-green` (opt-in, read-only).** A new `build-release.sh` flag
that, before archiving, runs:

```bash
gh api "repos/bbingz/engram/commits/$GIT_HEAD/check-runs" \
  --jq '.check_runs[] | select(.name|test("Tests")) | .conclusion'
```

and requires at least one `Tests`-workflow check-run with `conclusion ==
"success"`. **Fail-closed**: if `gh` is unauthenticated, the network is
unreachable, or the query returns no runs (unpushed commit, CI still running),
the flag *blocks with an explanatory message* — it never silently passes.
Because `release.yml` exists only after a `v*` tag, the flag requires the
`Tests` workflow only, not the Release Gate; it warns when HEAD is untagged
rather than demanding a gate that cannot exist yet. Off by default, since a clean
local HEAD is often unpushed.

**A5. Nothing tags or publishes.** All A-changes are a plist stamp, a verifier
assertion, and a read-only `gh api` GET. Stays inside `docs/TODO.md:31-33`.

#### Part A — Implementation slices

Each slice is independently landable.

- **A-slice 1 — inject.** `project.yml` two keys + two settings defaults;
  `build-release.sh` `GIT_HEAD`/`GIT_DIRTY` hoist + archive-command threading;
  run `xcodegen generate`. *Done when:* an archived bundle's Info.plist carries
  `EngramGitCommit == $(git rev-parse HEAD)` and `EngramGitDirty` matching the
  tree state, and `build-release.sh:117-128`-style assertion confirms it.
- **A-slice 2 — verify + tests.** `release-verify.sh` token guard, optional
  `--expected-git-head` (with an `ok: git-head` line on match), distributable
  `EngramGitDirty=="0"` assertion; `build-release.sh` passes
  `--expected-git-head`. Extend `tests/scripts/build-release-script.test.ts`: a
  provenance-stamped stub run `--adhoc --expected-git-head <hex>` prints the
  pre-signature `ok: git-head <hex>` substring (asserted on output, **not** exit 0
  — the stub fails codesign `:129`, exactly like the existing clean-stub test at
  `:132-138`); a stub with a mismatched `--expected-git-head` exits non-zero with
  `!= expected` (the mismatch `fail` fires before codesign); a stub with
  `EngramGitCommit == "$(ENGRAM_GIT_COMMIT)"` exits non-zero on the token guard
  (also before codesign); a script-text assertion that `release-verify.sh`
  contains the non-`--adhoc`-gated `EngramGitDirty=="0"` clause; and a script-text
  assertion that `build-release.sh` threads `ENGRAM_GIT_COMMIT`/`ENGRAM_GIT_DIRTY`
  onto the archive command. **Note:** the existing `runVerify` helper hardcodes
  `--adhoc` (`:99`); the dirty-distributable path (non-`--adhoc`) is covered by
  the script-text assertion, not a runtime run, because a stub cannot pass
  codesign `:129` in non-`--adhoc` mode and never reaches the distribution block.
  *Done when:* all new cases pass and every existing case in that file still
  passes unchanged.
- **A-slice 3 — `--require-ci-green`.** The opt-in gh gate. *Done when:* a
  script-text test asserts the flag exists, calls `gh api …/check-runs`, and
  fails-closed on empty output; and the flag is absent from the default archive
  path.
- **A-slice 4 — ledger.** Add invariant **#16 Release Bundle Provenance** to
  `docs/invariants.md`, carrying every field the existing entries #1–#13 use —
  Statement ("release bundles carry their producing commit SHA in
  `EngramGitCommit`; distributable bundles are git-clean
  (`EngramGitDirty == '0'`)"); Enforced by `macos/scripts/release-verify.sh`,
  `macos/scripts/build-release.sh`; Verified by
  `tests/scripts/build-release-script.test.ts` provenance cases; **Gate**
  `macos-vitest in .github/workflows/test.yml` (the vitest job that runs
  `build-release-script.test.ts`, mirroring #12's gate at
  `docs/invariants.md:52`). Then register the new invariant in
  `scripts/invariant-gates.json`: add `"16": ["ledger-paths"]` to the
  `invariants` map (`:35-49`), where #1–#13 are each already registered with at
  least `["ledger-paths"]`; without this, #16 is the sole unregistered invariant
  (the check still passes because path extraction is global, but the registry
  drifts). Then run `scripts/check-invariants-ledger.sh`. **Collision note
  (integration pass, 2026-07-24 — authoritative):** three specs append a new
  ledger entry, and the integration pass fixes their numbers so they do not
  collide. **14** = `docs/insight-supersede-filter-design-2026-07.md` (row 1,
  accepted, sequenced first — "Superseded insights"); **15** =
  `docs/publish-readiness-design-2026-07.md` (rows 0/6/18 — "Public Copy Matches
  Shipped Reality"); **16** = this spec ("Release Bundle Provenance"). The
  numbers are sequential, not semantic. If the recorded landing order changes,
  re-sequence the tail so the appended entries stay contiguous, but keep this
  spec's entry **last of the three** — it has the fewest cross-references and is
  publish-decision-independent, so it is the cheapest to renumber. Apply the same
  number in **both** `docs/invariants.md` and the `scripts/invariant-gates.json`
  `invariants` map.

#### Part A — Acceptance criteria (falsifiable)

1. An archived Engram.app built from a clean checkout has
   `PlistBuddy -c 'Print EngramGitCommit'` equal to `git rev-parse HEAD` and
   `Print EngramGitDirty` == `0`.
2. The same build from a dirty tree has `EngramGitDirty` == `1` and a non-empty
   40-hex `EngramGitCommit`.
3. On a matching `--expected-git-head`, `release-verify.sh` emits an
   `ok: git-head <sha>` line before codesign; on a mismatched SHA it exits
   non-zero with a `!= expected` message. (The mismatch/`ok` behavior is
   stub-testable because both fire before codesign `:129`; a full green exit —
   the positive "passes" end state — is validated only against a real signed
   bundle in CI / manual runs, since a stub cannot pass codesign `:129`.)
4. `release-verify.sh <dirty-bundle>` (non-`--adhoc`) fails on `EngramGitDirty`,
   and the same bundle with `--adhoc` skips that check — validated against a
   **real** signed bundle, not the stub harness (the dirty check lives in the
   distribution-only block after codesign `:129`, which a stub cannot reach, same
   status as the sibling Hardened-Runtime / Developer-ID / timestamp assertions
   at `:141-155`). In the stub harness this is covered only by a script-text
   assertion that the non-`--adhoc`-gated `EngramGitDirty=="0"` clause exists.
5. A bundle whose `EngramGitCommit` is the literal `$(ENGRAM_GIT_COMMIT)` fails
   the token guard in every mode that reaches the version/provenance stage — i.e.
   not `--hygiene-only`, which exits at `:106` before that stage (exactly as the
   existing version-token guard at `:117-119` is also skipped under
   `--hygiene-only`).
6. `build-release.sh --require-ci-green` on an unpushed HEAD exits non-zero with
   an explanatory message and performs **no** archive (stub-testable via
   script-text: the fail-closed branch). The success branch — on a pushed HEAD
   whose `Tests` run concluded `success` it proceeds — is **manual /
   non-CI-verifiable** (needs a live pushed commit + network + the confirmed
   check-run name, see the open question); A-slice 3's only automated coverage is
   the fail-closed script-text guard.
7. `npm run lint` and the full `tests/scripts/build-release-script.test.ts`
   suite pass; no Swift source and no file under `macos/Engram/` is modified by
   Part A.
8. `scripts/check-invariants-ledger.sh` passes with the new entry present.
9. `build-release.sh` contains no `git tag`, `gh release`, or `git push`.

---

### Part B — App-process perf instrumentation (row 16)

**B1. New file `macos/Engram/Support/PerfSignpost.swift`, DEBUG impl + Release
no-op in the same file, same commit.** Port the as-main shape verbatim with two
changes: subsystem `com.engram.perf` (service already owns `com.engram.service`;
a distinct subsystem stays Instruments-filterable), and env gate
`ENGRAM_PERF_MONITOR`. Include:

- `#if DEBUG enum Perf` — `Span`, `begin(_:thresholdMs:_:)` (`@escaping
  @autoclosure detail`, 16ms default), `end(_:_:)` (lazy detail, print over
  threshold), `event(_:_:)`. Preserve `@escaping @autoclosure` exactly: it is the
  efficiency property — under-threshold spans (the common case) never build the
  interpolated string.
- `#if DEBUG @MainActor final class MainThreadStallMonitor` — `.shared`,
  `DispatchSourceTimer` on `.main`, 50ms interval / 200ms stall threshold;
  `start()` no-ops unless `ENGRAM_PERF_MONITOR` is set.
- `#else` — Release shim covering **only** `enum Perf` (empty `Span`,
  `@inline(__always)` no-op `begin`/`end`/`event`), signature-identical.

**Exclude `PerfBench`** (non-goal).

**B2. Instrument the four sites, snapshotting volatile locals before `begin()`.**
Because `detail` is evaluated at `end()` time, capture the loop-variant values
into a `let` first (as-main `:35-38`):

- `parseWindow` (`SessionDetailView.swift:992`): capture `offset`, `limit`,
  `session.messageCount` before `begin`; `defer Perf.end(span)`.
- `rebuildIndexed` (`:1006`): capture `messages.count`.
- `loadData` (`SessionsPageView.swift:316`): capture `pageSize`,
  `sessions.count`.
- `loadMoreIfNeeded` (`:449`): capture `offset`, `pageSize`.

These four `Perf.begin/end` calls stay **unguarded** — the Release shim compiles
them to no-ops.

**B3. Start the stall monitor under `#if DEBUG` only.** In
`App.swift:91` `applicationDidFinishLaunching`:

```swift
#if DEBUG
MainThreadStallMonitor.shared.start()
#endif
```

This call site **must** be `#if DEBUG`-guarded: the Release shim does not provide
`MainThreadStallMonitor`, so an unguarded call fails to compile in Release — the
exact `838c7396` regression. `start()` itself no-ops without `ENGRAM_PERF_MONITOR`,
so a normal DEBUG launch pays nothing.

**B4. Compose with row 27, don't couple.** Row 27's O(n) transcript-paging repro
shares the `parseWindow` / `MessageParser.parseWindowed` seam, but it is an
**xctest of `MessageParser`** with a budget assertion, whereas Part B is a DEBUG
UI **signpost** with no CI coupling. Keep them separate instruments on the same
seam; neither belongs in `perf.yml`'s indexer budget. If row 27 lands first, Part
B's `parseWindow` span wraps the same call it measures — no conflict.

#### Part B — Implementation slices

- **B-slice 1 — the shim.** Add `PerfSignpost.swift` (DEBUG impl + Release
  no-op), `xcodegen generate`. *Done when:* both a Debug and a Release build of
  the `Engram` scheme compile with the file present and no call sites yet.
- **B-slice 2 — instrument + launch hook.** Add the four spans (B2) and the
  `#if DEBUG` `start()` (B3). *Done when:* a Debug build with
  `ENGRAM_PERF_MONITOR=1` prints `[perf]` span lines over 16ms and
  `[perf][STALL]` lines on an induced main-thread block, and the Release build
  still compiles.
- **B-slice 3 — regression guard test.** Add a `tests/scripts` case (established
  TS-dev-tooling pattern) asserting `PerfSignpost.swift` contains both `#if
  DEBUG` and `#else`, that `MainThreadStallMonitor` appears only inside the DEBUG
  region, and that the env gate string is `ENGRAM_PERF_MONITOR` (not
  `ENGRAM_PERF`). This is the cheap, durable guard against the `838c7396`
  Release-break, since there is no app-target unit-test bundle.

#### Part B — Acceptance criteria (falsifiable)

1. `xcodebuild -scheme Engram -configuration Release build` succeeds with
   `PerfSignpost.swift` and all four spans and the launch hook present.
2. A Debug run with `ENGRAM_PERF_MONITOR=1`, opening a >5,000-message session,
   emits at least one `[perf] parseWindow …ms` and one `[perf] rebuildIndexed
   …ms` console line, and the same spans appear as Instruments os_signpost
   intervals under subsystem `com.engram.perf`.
3. A Debug run **without** `ENGRAM_PERF_MONITOR` starts no stall timer
   (`MainThreadStallMonitor.shared.start()` returns early) — verified by the
   absence of any `[perf][STALL]` output under an induced 500ms main-thread
   block.
4. `grep -rE 'Perf\.(begin|end|event)|MainThreadStallMonitor' macos/Engram | grep
   -v PerfSignpost.swift` shows the four span sites (`Perf.begin`/`Perf.end`) and
   the one guarded launch call (`MainThreadStallMonitor`) only; no other app code
   references the types. (Grepping `os_signpost` here would match **nothing**
   outside `PerfSignpost.swift` — the span sites call `Perf.begin/end`, and
   `os_signpost` is emitted only inside the shim.)
5. `perf.yml` is byte-unchanged.
6. The B-slice-3 guard test passes; `ENGRAM_PERF` does not appear as the stall
   gate name.

Criteria **2 and 3 are manual acceptance evidence** (Instruments / console runs),
**not CI gates**: there is no app-target unit-test bundle to host runtime span/stall
assertions (Test plan). The **sole CI gate** for row 16 is criterion 6's
B-slice-3 script-text guard, and criteria 1 and 5 (Release build succeeds, `perf.yml`
unchanged) are checkable in CI. Slice ordering reflects that Part B lands on the
grep guard alone.

## Invariants affected

**Part A** touches **no existing** invariant. It proposes **new invariant #16
Release Bundle Provenance** (added to the ledger in A-slice 4; number assigned by
the integration pass — see the A-slice 4 collision note, which authoritatively
splits 14/15/16 across rows 1, 0-6-18, and 15-16), composed *beside*
**#7 Bundle Hygiene** (`docs/invariants.md:47-53`) — #7 asserts what the bundle
must *not* contain; #16 asserts what it *must* record. #7 is unmodified.

**Part B** touches **no** invariant. It adds no schema, no IPC command, no read
method, no tier logic; the Release path is a no-op. In particular **#2 Subagent
Sessions Stay Skip**, **#3 Tier Visibility**, and **#9 Startup Backfills** are
untouched — Part B never writes the database.

## Alternatives considered

**A: PlistBuddy stamp after export.** The obvious shortcut. Lost because
Info.plist is inside the signed seal; a post-export edit fails
`release-verify.sh:129` `codesign --verify --deep --strict`. Pre-archive
injection is mandatory.

**A: Store only the commit *count* (status quo) or a build-freshness TTL.** A
count is a height, not an identity, and collides across branches; a TTL answers
"is this stale", not "which commit". as-main's `deploy-agent-sessions.sh`
writes a QA-stamp bound to a maintainer QA-run HEAD (`:65,:72-73`) precisely
because its tests are maintainer-Mac-only. Engram's CI-on-tag already gates the
release commit, so the gap is *recorded provenance*, not expiry. Rejected.

**A: Also stamp the CI ad-hoc archive lane (`release.yml:150-162`) with
`github.sha` / dirty=0.** Natural, and it would let the ad-hoc gate assert
provenance too. Rejected for *this* spec to keep the change to the local build
path (row 15's stated scope) and the diff minimal. It is safe to add later: the
verifier's distributable dirty-check runs only in non-`--adhoc` mode, so the CI
ad-hoc lane is unaffected until it opts in. Left as a follow-up, not a
requirement.

**A: `--require-ci-green` also demands the Release Gate.** Rejected: `release.yml`
exists only after a `v*` tag, so on an untagged release HEAD it cannot be green.
The flag requires the `Tests` workflow only and warns when untagged.

**B: Guard every span site with `#if DEBUG`.** Rejected: that is exactly the
noise the Release no-op shim exists to remove. Only the `MainThreadStallMonitor`
launch call needs the guard, because the shim omits that type.

**B: Reuse the service `ServiceTelemetryCollector` or extend
`PerformanceView`.** Rejected: those measure cross-socket IPC command latency;
Part B measures app-local async UI wall-clock and main-thread stalls — a
different mechanism (Instruments + console) and a different surface. Zero overlap.

**B: Name the stall gate `ENGRAM_PERF`.** Rejected: `perf.yml:71` already sets
`ENGRAM_PERF=1`; the shortened name would silently couple two unrelated switches.

## Test plan

**Part A** — `tests/scripts/build-release-script.test.ts` (existing harness):

- `it('reports git-head ok for a provenance-stamped clean stub', …)` — stub with
  `EngramGitCommit=<40-hex>`, `EngramGitDirty=0`, run
  `--adhoc --expected-git-head <hex>`; assert the output **contains**
  `git-head <hex>` (the pre-signature `ok:` line), **not** exit 0 — the stub
  fails codesign `:129` and never exits 0, exactly like the existing clean-stub
  test (`build-release-script.test.ts:132-138`). A full green exit is validated
  only on a real signed bundle (CI / manual), not the stub harness.
- `it('rejects a mismatched --expected-git-head', …)` → non-zero, `!= expected`
  (the mismatch `fail` fires before codesign, so this is genuinely stub-testable).
- `it('rejects an unsubstituted provenance token', …)` — stub with
  `EngramGitCommit=$(ENGRAM_GIT_COMMIT)` → non-zero, token-guard message (the
  token guard also runs before codesign).
- `it('release-verify.sh dirty-distributable clause is present and non-adhoc-gated', …)`
  — **script-text** on `release-verify.sh`: the `EngramGitDirty=="0"` assertion
  exists inside the distribution-only (non-`--adhoc`) block. A runtime stub run
  cannot exercise it — non-`--adhoc` dies at codesign `:129` before the
  distribution block, and `runVerify` hardcodes `--adhoc` (`:99`) anyway — so the
  dirty-distributable rejection is validated on a real bundle, matching the
  established convention that distribution-only signature assertions are not
  stub-tested (`build-release-script.test.ts:126-131`).
- `it('build-release.sh threads git provenance onto the archive command', …)` —
  script-text: contains `ENGRAM_GIT_COMMIT="$GIT_HEAD"` and
  `ENGRAM_GIT_DIRTY="$GIT_DIRTY"`.
- `it('--require-ci-green queries check-runs and fails closed', …)` —
  script-text: contains `gh api` `…/check-runs`, and a fail-closed branch on
  empty output.

`buildStubApp` (`:28-76`) must gain optional `gitCommit` / `gitDirty` Info.plist
keys; defaults keep every existing call site unchanged.

**Part B** — `tests/scripts` guard test (B-slice 3): read
`macos/Engram/Support/PerfSignpost.swift`, assert it contains `#if DEBUG` and
`#else`, that `MainThreadStallMonitor` occurs only before the `#else`, and that
`ENGRAM_PERF_MONITOR` (not a bare `ENGRAM_PERF`) is the gate.

**Intentionally not tested (Part B):** the DEBUG span/stall runtime behavior has
no app-target unit-test bundle to host it (the `Engram` scheme's tests are
`EngramCoreTests`, which cover Core, not the SwiftUI app target), and the
Release path is a verified no-op, so there is no product behavior to assert.
Runtime verification is manual (Instruments/console), per acceptance criteria
2–3. This exemption is explicit precisely because CLAUDE.md requires tests for
production-path behavior changes and Release carries none here.

## Rollout

**Part A**: no version bump, no schema, no migration. Ships with the next
`build-release.sh` run; the stamp appears in the next archive. Revert = drop the
two `project.yml` keys, the `build-release.sh` threading, and the verifier
clause; already-stamped bundles keep an inert extra plist key.

**Part B**: DEBUG-only; Release ships a no-op. Ships with the next `EngramService`
/ app build after `xcodegen generate`. No user-visible change in Release. Revert
= delete `PerfSignpost.swift`, the four spans, and the launch hook.

Neither part is coupled to a publish decision (row 0).

## Risks and open questions

**Medium — an unsubstituted provenance token could ship if the verifier clause
is skipped.** `release-verify.sh:117-119` today guards only the two version keys;
A3's extension is the fix, but if A-slice 2 lands the injection (A-slice 1) and
not the guard, a mis-configured build could ship a literal token. Mitigation:
land A-slices 1 and 2 together, or gate the release on A-slice 2.

**Medium — `--require-ci-green` depends on gh auth + network + a pushed commit.**
Fail-closed is the chosen policy (A4), but a maintainer building a legitimately
unpushed clean HEAD must know to omit the flag. Documented as opt-in.

**Medium — Part B spans measure async wall-clock, not main-thread block.** If a
reader treats a `parseWindow` span as main-thread cost they will draw the wrong
conclusion about a beachball. Mitigated by stating the span-vs-stall-monitor
distinction in B (Current state + B4), but it is a documentation-load-bearing
distinction, not an enforced one.

**Low — Part B ships with no automated runtime test.** Reviewers expecting a
`_repro` per CLAUDE.md may push back; the Release-no-op exemption is stated
explicitly (Test plan) and the B-slice-3 grep guard is the durable protection
against the one real failure mode (Release break).

**Open question — should the CI ad-hoc lane (`release.yml`) also stamp
provenance?** Deferred to a follow-up (Alternatives). Left open: whether an
ad-hoc CI bundle should carry `github.sha` so tag-time verification can assert
its commit. Not required by row 15's scope; decide when the CI lane next changes.

**Open question — exact `--require-ci-green` matcher for the `Tests` workflow.**
`gh api …/check-runs` returns check-run `name`s; the design filters on
`name ~ "Tests"`. If the workflow's check-run name differs from the workflow
`name:` (`test.yml:1` is `Tests`), the matcher needs the actual check-run name,
which must be confirmed against a real pushed commit during A-slice 3.

**Open question — does `git rev-parse HEAD` in `build-release.sh` run against
`$MACOS_DIR` or the repo root?** A2 uses `-C "$MACOS_DIR"` for parity with the
existing `WORKTREE_DIRTY` probes (`:68-70`), which are already scoped to
`$MACOS_DIR`. That is a subdirectory of the same repo, so `rev-parse HEAD`
returns the whole-repo HEAD; confirmed harmless, noted for the implementer.
