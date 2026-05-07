---
name: macOS signing — use real Developer cert, never ad-hoc by default
description: Build/sign rule for the Engram macOS app — query keychain for Team ID before falling back to ad-hoc signing
type: feedback
originSessionId: 3991d669-3667-4fa8-9d5b-8b62ad72f10e
---
When `xcodebuild` fails because `project.yml` has `DEVELOPMENT_TEAM: YOUR_TEAM_ID` (the open-source placeholder), do NOT silently fall back to `CODE_SIGN_IDENTITY="-"` (ad-hoc). The user has a real Apple Developer cert and expects it to be used.

**Why:** The repo is intentionally sanitized — `YOUR_TEAM_ID` and `ExportOptions.plist` `teamID=YOUR_TEAM_ID` are placeholders, not missing config. Real Team ID lives in keychain, not in tracked files. User pushed back when I went ad-hoc without asking ("我有开发者签名啊？你干嘛？").

**How to apply:**
1. Run `security find-identity -v -p codesigning` first — read the parenthesized Team ID from `Developer ID Application: <name> (XXXXXXXXXX)`. Current value: `J25GS8J4XM`.
2. Override on the command line, do NOT edit `project.yml`:
   `xcodebuild ... DEVELOPMENT_TEAM=J25GS8J4XM CODE_SIGN_STYLE=Automatic`
3. The proper release path is `macos/scripts/build-release.sh` driven by `ENGRAM_TEAM_ID=J25GS8J4XM`. Use it for full archive/export/notarize. For a quick "build + drop into /Applications" use the direct `xcodebuild` form above.
4. Only fall back to ad-hoc with explicit user permission.
