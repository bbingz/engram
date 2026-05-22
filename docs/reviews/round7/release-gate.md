# Round 7 — Release Gate Deep Dive (2026-05-22)

Read-only confirmation of round-6 §11 (release process) defects against the
actual scripts/config, plus a design for a *real* release gate (not theater).

All file:line citations verified by reading the live files in this repo.
Signature/bundle facts verified against a real built bundle on disk
(`~/Library/Developer/Xcode/DerivedData/Engram-apkspuobooepqkdrdnbizljrophn/Build/Products/Debug/Engram.app`).

---

## Part 1 — Defect confirmation (each round-1 claim)

### F1 CONFIRMED (CRITICAL) — export fallback ships an un-notarizable app while printing "Build complete!"
`macos/scripts/build-release.sh`:
- The archive is built with **automatic** signing (line 54: `CODE_SIGN_STYLE=Automatic`),
  and the app target's identity in `macos/project.yml:197` is
  `CODE_SIGN_IDENTITY: "Apple Development"`. So the archived app is signed
  `Apple Development`, NOT `Developer ID Application`.
- Export uses `developer-id` method (`macos/ExportOptions.plist:5-6`:
  `<key>method</key><string>developer-id</string>`). An archive signed with an
  `Apple Development` identity has **no Developer-ID distribution method**, so
  `xcodebuild -exportArchive` fails with "no available distribution methods".
- The fallback (lines 69-83) catches exactly that error string and then
  `ditto`-copies the archived (Apple-Development-signed) app verbatim:
  ```
  83:    ditto "$ARCHIVED_APP" "$EXPORT_PATH/Engram.app"
  ```
- The only post-fallback check is `codesign --verify --strict` (line 94),
  which validates seal integrity, **not** signing identity. The script then
  unconditionally prints `Build complete!` (line 99).
- **Empirical proof of the "verify passes but notarization won't" mechanism**
  (run against the real Debug bundle, which is also `Apple Development`-signed):
  - `codesign -dvvv` → `Authority=Apple Development: zhibing zhao (AE7P4G8656)`,
    `flags=0x0(none)`, and **no `Timestamp=` line**.
  - `codesign --verify --deep --strict` → `valid on disk` /
    `satisfies its Designated Requirement` (i.e. `--verify` is happy).
  - notarytool would reject this because notarization requires a
    **Developer ID Application** certificate, **Hardened Runtime**
    (`flags=0x10000(runtime)`), and a **secure timestamp** — none present.
  Verdict: the fallback produces a locally-runnable but Gatekeeper-blocked,
  un-notarizable artifact that the script advertises as a finished release.

### F2 CONFIRMED (CRITICAL) — release test asserts script TEXT, never behavior
`tests/scripts/build-release-script.test.ts` reads the script as a string
(lines 6-9) and only does `expect(script).toMatch(...)` / `toContain(...)` /
`indexOf` ordering (lines 12-31). It never executes the script and never
inspects a bundle. It literally pins the grep regex text (lines 13-15) and the
removal of `--deep` (line 30: `expect(script).not.toContain('codesign --verify --deep')`).
It cannot catch F1, a wrong signing identity, forbidden bundle contents, or a
non-running binary.

### F3 CONFIRMED (HIGH) — bundle-hygiene rules enforced by nothing
CLAUDE.md says the bundle "must not include `Contents/Resources/node`,
`node_modules`, `dist`, `daemon.js`, `index.js`, or `web.js`". Grep for any of
`node` / `node_modules` / `dist` / `daemon.js` across `macos/scripts/` and
`macos/project.yml` build phases returned **zero matches**. No script, build
phase, test, or CI step asserts the absence of these paths. Prose only.

### F4 CONFIRMED (HIGH) — no scripted deploy
There is no deploy script anywhere. The "rm -rf then cp -R; cp -R silently
skips running binaries" guidance lives only in CLAUDE.md prose. `build-release.sh`
stops at export + prints manual notarize/staple/DMG instructions (lines 104-131).
No quit-app, no `ditto` install, no installed-version verification.

### F5 CONFIRMED (HIGH) — no Hardened Runtime → notarization impossible regardless
- `macos/Engram/Engram.entitlements` is an **empty dict** (lines 4-7, comments only).
- No `ENABLE_HARDENED_RUNTIME` anywhere in `macos/project.yml` (grep of all
  signing keys returns only `CODE_SIGNING_ALLOWED`, `CODE_SIGN_IDENTITY`,
  `CODE_SIGN_STYLE`, `CODE_SIGN_ENTITLEMENTS`, `DEVELOPMENT_TEAM`).
- `macos/ExportOptions.plist` has no `hardenedRuntime` key.
- Empirically, the built bundle reports `flags=0x0(none)` — Hardened Runtime
  off. Apple notarization rejects software without the runtime hardening flag.

### F6 CONFIRMED (HIGH) — static, uncoordinated versions, no bump
- `macos/Engram/Info.plist:20` `CFBundleShortVersionString = 1.0`,
  `:22` `CFBundleVersion = 1` (hardcoded literals, not build-var driven).
- `package.json:3` `"version": "0.1.0"`.
- The two version sources disagree (1.0/1 vs 0.1.0) and nothing reconciles or
  auto-increments them. `build-release.sh` performs no version bump.

### F7 CONFIRMED (MEDIUM) — helper re-sign uses `--timestamp=none`; `--deep` verify removed; fragile PlugIns heuristic
- `macos/scripts/copy-service-helper.sh` re-signs with `--timestamp=none` at
  lines 21, 32, 40, 44, 51. `macos/scripts/copy-mcp-helper.sh:21` likewise.
  notarytool requires a **secure timestamp**; `--timestamp=none` is rejected.
- The whole outer re-sign block is gated on `! -d "${APP}/Contents/PlugIns"`
  (copy-service-helper.sh:37). The real Debug bundle **does** have a `PlugIns/`
  directory, so in that build the outer re-seal branch is silently skipped —
  a fragile presence heuristic, not an intentional contract.
- `--deep` verify was removed and the removal is *pinned by a test*
  (`build-release-script.test.ts:30`), so re-adding deep verification would
  break the existing test — verification theater locked in by a test.

### F8 CONFIRMED (HIGH/MEDIUM) — no CI release lane
`.github/workflows/test.yml` is the only workflow. Its jobs are `lint`,
`dead-code`, `typescript`, `swift-unit`, `fixture-check`, `ui-test-smoke`,
`ui-test-full`. Triggers are `push`/`pull_request` on `main` (lines 3-7) — no
tag trigger. Every Swift xcodebuild step forces `CODE_SIGNING_ALLOWED=NO`
(line 100) or `CODE_SIGN_IDENTITY="-"` (lines 164, 251). Nothing archives,
exports, or inspects a release bundle.

### F9/F10 CONFIRMED (LOW)
- F9: `build-release.sh:11-12` writes the archive/export under
  `$MACOS_DIR/build/...` — `macos/build/` is the gitignored stale-cache dir
  CLAUDE.md says NOT to use.
- F10: `build-release.sh:24-32` only guards against the literal placeholder
  `REPLACE_TEAM_ID`; the real `teamID` is already filled in
  (`ExportOptions.plist:8` = `J25GS8J4XM`), so the guard is dead.

---

## Part 2 — The fallback signature problem (mechanism)

- **What signs the archive:** `project.yml:197` `CODE_SIGN_IDENTITY: "Apple Development"`
  + `CODE_SIGN_STYLE: Automatic` (build-release.sh:54). Result: the archived
  `Engram.app` carries an **Apple Development** leaf certificate (a *development*
  cert, valid for local run / dev distribution only).
- **What `developer-id` export requires:** a **Developer ID Application**
  certificate. The signing machine *has* one
  (`security find-identity`: `Developer ID Application: zhibing zhao (J25GS8J4XM)`),
  but the archive was never signed with it, so the archive exposes no
  Developer-ID export method → export fails → fallback ditto-copies the
  development-signed app.
- **Why `codesign --verify` passes:** `--verify --strict` checks that the code
  hashes match the sealed CodeDirectory and the embedded chain is internally
  consistent (the development chain is a valid chain). It does **not** assert
  the leaf is Developer ID, nor that Hardened Runtime / secure timestamp exist.
  Confirmed: `codesign --verify --deep --strict` on the development-signed
  bundle prints `valid on disk` and `satisfies its Designated Requirement`.
- **Why notarization would fail:** notarytool requires (1) a Developer ID
  Application cert, (2) the Hardened Runtime flag (`0x10000`), (3) a secure
  timestamp. The fallback artifact has none. So `codesign --verify` is a
  necessary-but-wildly-insufficient check; it is the core of the theater.

---

## Part 3 — Bundle-hygiene check absence

Confirmed (Part 1 F3). Empirically, the current Debug bundle is *coincidentally*
clean (the forbidden-path scan found none of node/node_modules/dist/daemon.js/
index.js/web.js), but that is not enforced — a regression that re-adds a Node
bundle phase would ship silently. Top-level `Contents/` of the real bundle:
`Frameworks/ Helpers/ MacOS/ PlugIns/ Resources/ _CodeSignature/ Info.plist PkgInfo`;
`Helpers/` holds `EngramMCP` + `EngramService`; `MacOS/` holds
`Engram`, `Engram.debug.dylib`, `__preview.dylib` (the latter two are
Debug-only artifacts that MUST NOT appear in a Release bundle — another thing
the hygiene loop should catch).

---

## Part 4 — Hardened Runtime absence

Confirmed (Part 1 F5). Triple-absent: empty entitlements, no
`ENABLE_HARDENED_RUNTIME` in project.yml, no `hardenedRuntime` in
ExportOptions; and empirically `flags=0x0(none)` on the built app.

---

## Part 5 — Real built bundle inspection

A Release bundle does NOT exist on disk (no
`.../Build/Products/Release/Engram.app`). Two **Debug** bundles exist; inspected
`Engram-apkspuobooepqkdrdnbizljrophn/.../Debug/Engram.app`:

| Check | Result |
|---|---|
| Top-level `Contents/` | Frameworks, Helpers, MacOS, PlugIns, Resources, _CodeSignature, Info.plist, PkgInfo |
| Forbidden paths (node/node_modules/dist/daemon.js/index.js/web.js) | none found |
| Debug-only artifacts present | `Engram.debug.dylib`, `__preview.dylib`, `PlugIns/` (must be absent in Release) |
| App signing authority | `Apple Development: zhibing zhao (AE7P4G8656)` |
| Hardened Runtime flag | `flags=0x0(none)` → OFF |
| Secure timestamp | none (`codesign -dvvv` shows no `Timestamp=`) |
| Helper (`EngramService`) authority | `Apple Development` (same dev cert) |
| `codesign --verify --deep --strict` | passes (`valid on disk`, `satisfies its Designated Requirement`) |

This Debug bundle is the proof object for the F1 mechanism: a development-signed
app that passes `codesign --verify` yet is un-notarizable. Caveat: it is a
**Debug** build; `Apple Development` is *expected* for Debug. The defect is that
`project.yml:197` hardcodes the same `Apple Development` identity for the
**Release** archive too, and the export fallback ships it.

---

## Part 6 — The real release gate (design)

### (a) `macos/scripts/release-verify.sh` — fail-loud bundle assertions
Takes a path to the exported `Engram.app`. Each assertion `exit 1`s with a
clear message on failure; the script is the post-export gate that `build-release.sh`
must call instead of bare `codesign --verify`.

```bash
#!/bin/bash
set -euo pipefail
APP="${1:?usage: release-verify.sh <path-to-Engram.app>}"
[[ -d "$APP" ]] || { echo "FAIL: not a bundle: $APP"; exit 1; }

fail() { echo "RELEASE-VERIFY FAIL: $*" >&2; exit 1; }

# 1. Developer ID Application authority (NOT Apple Development).
DV=$(codesign -dvvv "$APP" 2>&1)
echo "$DV" | grep -q "Authority=Developer ID Application" \
  || fail "signing authority is not 'Developer ID Application' (got: $(echo "$DV" | grep -m1 '^Authority='))"
echo "$DV" | grep -q "Authority=Apple Development" \
  && fail "bundle is signed with 'Apple Development' (development cert, cannot notarize)"

# 2. Hardened Runtime flag present (0x10000 runtime).
echo "$DV" | grep -qiE "flags=0x[0-9a-f]*1[0-9a-f]{4}.*runtime|CodeDirectory.*runtime" \
  || codesign -d --verbose=4 "$APP" 2>&1 | grep -qi "runtime" \
  || fail "Hardened Runtime flag missing (notarization requires it)"

# 3. Secure timestamp present.
echo "$DV" | grep -q "^Timestamp=" \
  || fail "no secure timestamp (helpers/app signed with --timestamp=none)"

# 4. Deep nested-signature validity (re-enables the removed --deep check).
codesign --verify --deep --strict --verbose=2 "$APP" \
  || fail "deep/strict signature verification failed"

# 5. Forbidden-path bundle-hygiene loop (enforce CLAUDE.md prose).
FORBIDDEN=(node node_modules dist daemon.js index.js web.js \
           Engram.debug.dylib __preview.dylib)
for name in "${FORBIDDEN[@]}"; do
  hit=$(find "$APP" -name "$name" -print -quit 2>/dev/null || true)
  [[ -z "$hit" ]] || fail "forbidden bundle path present: $hit"
done
# Release bundle must not carry a PlugIns dir (Debug-only previews).
[[ ! -d "$APP/Contents/PlugIns" ]] || fail "Contents/PlugIns present (Debug artifact)"

# 6. Helpers exist and are themselves Developer-ID + timestamped.
for h in EngramService EngramMCP; do
  hp="$APP/Contents/Helpers/$h"
  [[ -f "$hp" ]] || fail "missing helper: $h"
  hd=$(codesign -dvvv "$hp" 2>&1)
  echo "$hd" | grep -q "Authority=Developer ID Application" || fail "$h not Developer-ID signed"
  echo "$hd" | grep -q "^Timestamp=" || fail "$h missing secure timestamp"
done

echo "RELEASE-VERIFY OK: $APP"
```

`build-release.sh` changes to make the gate meaningful:
- Set the Release identity to Developer ID. Add to the `Engram` target in
  `project.yml` (or override on the archive command):
  `CODE_SIGN_IDENTITY[config=Release]: "Developer ID Application"`,
  `OTHER_CODE_SIGN_FLAGS: "--timestamp"`,
  `ENABLE_HARDENED_RUNTIME: YES`, and use a `developer-id` `signingStyle: manual`
  for the archive step (or keep Automatic but with the Developer-ID cert).
- DELETE the ditto fallback (lines 69-86). If `developer-id` export fails, that
  is a hard error, not a "ship the dev build anyway" path.
- Replace line 94's bare `codesign --verify` with
  `"$SCRIPT_DIR/release-verify.sh" "$EXPORT_PATH/Engram.app"`.
- Set entitlements + hardened runtime so the runtime flag is present at sign time.

### (b) Version single-sourcing + CFBundleVersion auto-bump
- Single source of truth: keep the semantic version in `package.json` (or a new
  `macos/Version.xcconfig`). Drive `CFBundleShortVersionString` from it instead
  of the hardcoded `1.0`.
- Change `Info.plist` to use build settings:
  `CFBundleShortVersionString = $(MARKETING_VERSION)`,
  `CFBundleVersion = $(CURRENT_PROJECT_VERSION)`, and set both in `project.yml`
  Engram-target `settings:`.
- Auto-bump: in `build-release.sh`, before archive, derive
  `CURRENT_PROJECT_VERSION` from the git commit count or CI run number
  (`agvtool` or `git rev-list --count HEAD`) and `MARKETING_VERSION` from
  `package.json`. Pass them as xcodebuild overrides so every release archive has
  a monotonically increasing, coordinated build number. Add a sanity assertion
  that `package.json` version == the marketing version used.

### (c) Scripted deploy `macos/scripts/deploy-local.sh`
```bash
#!/bin/bash
set -euo pipefail
APP="${1:?usage: deploy-local.sh <path-to-Engram.app>}"
DEST="/Applications/Engram.app"
"$(dirname "$0")/release-verify.sh" "$APP"          # never deploy a bad bundle

osascript -e 'quit app "Engram"' 2>/dev/null || true
pkill -x Engram 2>/dev/null || true
sleep 1
rm -rf "$DEST"                                       # cp -R silently skips running binaries
ditto "$APP" "$DEST"                                 # ditto preserves signature/xattrs

want=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$APP/Contents/Info.plist")
got=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$DEST/Contents/Info.plist")
[[ "$want" == "$got" ]] || { echo "FAIL: installed CFBundleVersion $got != $want"; exit 1; }
echo "Deployed Engram $got to $DEST"
```

### (d) CI release lane (tag-gated, ad-hoc identity)
New job in a workflow triggered on `push: tags: ['v*']` (CI has no Developer-ID
secret, so it signs ad-hoc `-` and runs the *structure/hygiene* assertions, not
the notarizable-identity ones):

```yaml
release-bundle:
  runs-on: macos-15
  if: startsWith(github.ref, 'refs/tags/v')
  steps:
    - uses: actions/checkout@v4
    - run: brew install xcodegen || true
    - run: cd macos && xcodegen generate
    - name: Archive (ad-hoc signed)
      run: |
        cd macos && xcodebuild archive \
          -project Engram.xcodeproj -scheme Engram -configuration Release \
          -archivePath build/Engram.xcarchive \
          CODE_SIGN_IDENTITY="-" CODE_SIGNING_ALLOWED=YES \
          ENABLE_HARDENED_RUNTIME=YES
    - name: Export app from archive
      run: |
        cd macos && cp -R build/Engram.xcarchive/Products/Applications/Engram.app build/Engram.app
    - name: Hygiene + structure assertions (identity-independent subset)
      run: |
        APP=macos/build/Engram.app
        for n in node node_modules dist daemon.js index.js web.js Engram.debug.dylib __preview.dylib; do
          if find "$APP" -name "$n" -print -quit | grep -q .; then echo "FAIL forbidden: $n"; exit 1; fi
        done
        test ! -d "$APP/Contents/PlugIns" || { echo "FAIL: PlugIns present"; exit 1; }
        test -f "$APP/Contents/Helpers/EngramService" || { echo "FAIL: missing EngramService"; exit 1; }
        test -f "$APP/Contents/Helpers/EngramMCP" || { echo "FAIL: missing EngramMCP"; exit 1; }
        codesign --verify --deep --strict --verbose=2 "$APP"
        v=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$APP/Contents/Info.plist")
        test "$v" != "1" || { echo "FAIL: CFBundleVersion not bumped"; exit 1; }
```

Note: CI cannot assert the Developer-ID-authority / secure-timestamp / notarytool
checks without the Developer ID cert + app-specific password in secrets; those
remain in the local `release-verify.sh` run on the signing machine. CI covers the
identity-independent half (structure, hygiene, deep-seal validity, version bump,
Hardened-Runtime-enabled archive).

### (e) Replace the text-matching test with a real bundle-structure test
Delete `tests/scripts/build-release-script.test.ts` (it pins the very theater we
are removing, incl. the `--deep` removal). Replace with a test that asserts on a
*built bundle*. Two options:
- **Swift** (preferred, runs in the existing `swift-unit`/`release-bundle` CI):
  an XCTest that takes `$BUILT_PRODUCTS_DIR/Engram.app`, walks `Contents/`, and
  asserts the forbidden-path set is absent, helpers exist, no `PlugIns/` in
  Release, and `codesign --verify --deep --strict` exits 0 (via `Process`).
- **Shell BATS / a Node test that EXECUTES `release-verify.sh`** against a
  fixture bundle layout (create a temp dir tree with/without forbidden files and
  assert the script exits non-zero on the bad layout, zero on the good one).
  This tests the *gate's behavior*, not its source text.

---

## Claims I could NOT fully verify (and why)
- **notarytool actually rejecting the artifact:** not run — requires Apple ID +
  app-specific password (secrets not present in this environment). The rejection
  is inferred from Apple's documented requirements (Developer ID cert + Hardened
  Runtime + secure timestamp) cross-checked against the bundle's observed
  `Apple Development` authority, `flags=0x0`, and absent `Timestamp=`.
- **Release-config behavior of the export fallback end-to-end:** no Release
  bundle exists on disk and `build-release.sh` was not executed (it would
  clean DerivedData and depend on signing infra). The fallback path was confirmed
  by reading the script; the *signature mechanism* was confirmed against the
  equivalently-signed Debug bundle.
- **Whether `PlugIns/` ever ships in a Release archive:** the `PlugIns/` dir was
  observed only in the Debug bundle (it carries `__preview.dylib` SwiftUI preview
  content). Release builds typically omit it, but this was not verified against
  an actual Release archive — hence the hygiene loop explicitly asserts its
  absence rather than assuming it.
