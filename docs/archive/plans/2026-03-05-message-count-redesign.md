# Message Count Redesign: Three-Dimensional Counting

## Problem

Current `messageCount` includes system injections (CLAUDE.md, environment_context, agent communication), inflating the number significantly. A session showing "318 msgs" may have only ~40 human messages.

## Design

### Data Model

Add two columns to `sessions` table:
- `assistant_message_count INTEGER NOT NULL DEFAULT 0`
- `system_message_count INTEGER NOT NULL DEFAULT 0`

Existing `message_count` becomes `user + assistant` only (no system). `user_message_count` stays as-is.

SessionInfo type adds:
```typescript
assistantMessageCount: number
systemMessageCount: number
```

### Classification Rules

Each adapter's `parseSessionInfo()` classifies messages into three buckets:

| Category | Criteria |
|----------|----------|
| **user** | role=user AND not system injection |
| **assistant** | role=assistant |
| **system** | role=user AND detected as system injection by `isSystemInjection()` / `classifySystem()` |

Reuse existing detection logic (`isSystemInjection` in TS adapters, `classifySystem` in Swift parser).

### Adapters to Update

All 14 adapters need count logic changes:
- claude-code, codex, copilot, cline, cursor, vscode
- gemini-cli, opencode, iflow, qwen, kimi
- antigravity, windsurf, lobsterai/minimax

### UI Display

Session list and detail header show all three dimensions:
```
12 user · 28 asst · 278 sys
```

Stats page aggregates all three.

Applies to both web (`src/web/views.ts`) and macOS app (`SessionListView.swift`, `SessionDetailView.swift`).

### Migration

1. Add columns with `ALTER TABLE` (default 0)
2. On daemon startup, detect sessions needing backfill (`assistant_message_count = 0 AND message_count > 0`)
3. Re-index those sessions to populate new counts
4. Swift side: read new columns in GRDB Session struct

### Files to Modify

**TypeScript:**
- `src/adapters/types.ts` — Add fields to SessionInfo
- `src/adapters/*.ts` — Update parseSessionInfo() in all adapters
- `src/core/db.ts` — Schema migration, upsert, rowToSession, statsGroupBy
- `src/web/views.ts` — Display format
- `src/web.ts` — API response (already returns SessionInfo)
- `src/daemon.ts` — Backfill trigger on startup

**Swift:**
- `macos/Engram/Core/Database.swift` — Read new columns
- `macos/Engram/Views/SessionListView.swift` — Display format
- `macos/Engram/Views/SessionDetailView.swift` — Display format
