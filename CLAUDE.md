# Engram

Cross-tool AI session aggregator: TypeScript MCP server + macOS SwiftUI menu bar app.

## Quick Reference

```bash
# TypeScript
npm run build          # tsc → dist/ (ES modules)
npm test               # vitest: 173 tests, ~2s
npm run dev            # tsx: run without compile

# macOS (from macos/)
xcodegen generate      # regenerate .xcodeproj from project.yml
xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build

# After changing src/, always: npm run build
# After adding/removing Swift files: xcodegen generate
```

## Architecture

```
src/
  adapters/    # SessionAdapter implementations (15 tools: codex, claude-code, cursor, etc.)
  core/        # db.ts (SQLite), indexer.ts, watcher.ts, config.ts, sync.ts, lifecycle.ts
  tools/       # MCP tool handlers (get_context, search, list_sessions, etc.)
  web.ts       # Hono HTTP server + API endpoints
  index.ts     # MCP server entry (stdin/stdout transport)
  daemon.ts    # Daemon entry (indexer + watcher + web server)

macos/
  Engram/      # SwiftUI app (menu bar)
    Core/      # IndexerProcess.swift (launches node daemon), Database.swift (GRDB read-only)
    Views/     # PopoverView, SessionListView, SearchView, SettingsView
    Models/    # Session.swift
  project.yml  # xcodegen config → generates Engram.xcodeproj
  scripts/build-node-bundle.sh  # Xcode prebuild: npm build → copy dist/ into app bundle
```

## Key Patterns

### Adapter Pattern
All 15 adapters implement `SessionAdapter` from `src/adapters/types.ts`:
- `detect()` — check if tool's session dir exists
- `listSessionFiles()` — async generator yielding file paths
- `parseSessionInfo()` — extract metadata from session file
- `streamMessages()` — async generator yielding messages lazily

New adapters: create `src/adapters/<name>.ts`, register in `src/core/bootstrap.ts:createAdapters()`.

### Database
- Node owns schema (`src/core/db.ts:migrate()`). Swift reads via GRDB (read-only pool).
- Swift writes only to extension tables: `favorites`, `tags`.
- Schema changes: add idempotent migration in `migrate()` (check `PRAGMA table_info` before `ALTER TABLE`).
- FTS: trigram tokenizer on `sessions_fts`. Version bump in `FTS_VERSION` forces full re-index.

### Process Lifecycle
`setupProcessLifecycle()` MUST be called AFTER `server.connect(transport)` — stdin race with StdioServerTransport.

### Daemon ↔ Swift Communication
- Daemon writes JSON lines to stdout: `{ event: "ready", indexed: N, total: M }`
- Swift `IndexerProcess` parses these events via pipe
- Daemon stderr → `os_log` (`com.engram.app:daemon`, viewable in Console.app)

## Conventions

- **Language**: TypeScript (strict, ES2022, Node16 modules) + Swift 5.9 (macOS 14+)
- **Constants**: UPPER_SNAKE_CASE (`WATCHED_SOURCES`, `NOISE_FILTER_SQL`)
- **Error handling**: Adapters silently skip failures; DB errors propagate; tools return `isError: true`
- **Tests**: Vitest with real fixtures in `tests/fixtures/<adapter>/`. No mocking — real file I/O.
- **Comments**: Chinese comments are intentional, keep them as-is

## Build Output

- Xcode builds to: `~/Library/Developer/Xcode/DerivedData/Engram-*/Build/Products/{Debug,Release}/Engram.app`
- Do NOT use `macos/build/` — stale cache, gitignored
- Bundle includes: `Contents/Resources/node/{daemon.js, ...dist files, node_modules/}`

## Data

- SQLite DB: `~/.engram/index.sqlite` (WAL mode)
- Settings: `~/.engram/settings.json`
- Session sources: `~/.claude/projects/`, `~/.codex/sessions/`, `~/.gemini/`, etc.

## What NOT To Do

- Don't modify generated `Engram.xcodeproj` directly — edit `project.yml` and run `xcodegen generate`
- Don't commit `.sqlite` files, `node_modules/`, or `dist/`
- Don't add `summary_message_count` column — it already exists (migration is idempotent)
- Don't use `String(value)` for potentially undefined values in TS — use `(value as string) || ''`
