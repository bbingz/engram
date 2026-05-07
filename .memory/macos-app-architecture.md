---
name: macOS app is Swift-native — TS src/ does not ship inside .app
description: Engram macOS app uses Swift EngramService/EngramMCP helpers, not the node daemon — TS-only fixes don't change the app
type: project
originSessionId: 3991d669-3667-4fa8-9d5b-8b62ad72f10e
---
The macOS app does NOT bundle the TypeScript daemon. `Contents/Resources/node/daemon.js` does not exist in current builds; the app is fully Swift-native.

**Why:** The app shipped a node bundle in earlier versions, but by 1.0.x the runtime is Swift: `Contents/Helpers/EngramMCP` (Swift MCP server) + `Contents/Helpers/EngramService` (Swift daemon, sockets at `~/.engram/run/engram-service.sock`) + `EngramServiceCore.framework` / `EngramCoreRead.framework` / `EngramCoreWrite.framework`. The repo's `CLAUDE.md` still describes the old node-bundle layout — it is outdated.

**How to apply:**
- TS-only edits under `src/` (e.g., the audit fixes round) ship via the npm package / standalone node MCP, not via the macOS .app. Don't claim "rebuild the app to pick up the TS fix."
- When deploying an app rebuild after TS changes, expect the .app to be functionally unchanged from the prior macOS build — only Swift edits move the needle.
- Do not look for `build-node-bundle.sh` (referenced in CLAUDE.md but does not exist).
- If asked to update CLAUDE.md, the architecture section under `macos/` and the "Build Output" bundle-includes line need rewriting.
