# PR4: Session Housekeeping — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enhance `computeTier()` to detect preamble-only, no-reply, and probe sessions, downgrading them to skip/lite tier for automatic noise filtering.

**Architecture:** Extend `TierInput` with `firstUserMessages` and `isPreamble` fields. New `preamble-detector.ts` module checks for system injection patterns (CLAUDE.md, environment_context, agents.md markers). Enhanced `computeTier()` uses these signals to downgrade meaningless sessions. Daemon backfills existing sessions on startup.

**Tech Stack:** TypeScript, existing session-tier.ts, Vitest tests

**Spec:** `docs/superpowers/specs/2026-03-19-eight-prs-learning-from-agent-sessions-design.md` (PR4 section)

---

## File Structure

### New Files
| File | Responsibility |
|------|---------------|
| `src/core/preamble-detector.ts` | Detect preamble-only content: CLAUDE.md markers, system-reminder, etc. |
| `tests/preamble-detector.test.ts` | Test preamble detection with real fixture samples |

### Modified Files
| File | Changes |
|------|---------|
| `src/core/session-tier.ts` | Extend TierInput, enhance computeTier() with preamble/no-reply/probe logic |
| `src/core/indexer.ts` | Extract firstUserMessages during indexing, pass to computeTier() |
| `tests/session-tier.test.ts` | Add tests for new tier downgrade scenarios |

---

## Task 1: Preamble Detector

**Files:** Create: `src/core/preamble-detector.ts`, `tests/preamble-detector.test.ts`

- [ ] **Step 1: Write failing tests**

```typescript
// tests/preamble-detector.test.ts
import { describe, it, expect } from 'vitest'
import { isPreambleContent, isPreambleOnly } from '../src/core/preamble-detector.js'

describe('preamble-detector', () => {
  it('detects CLAUDE.md content', () => {
    expect(isPreambleContent('Contents of CLAUDE.md\n# Project\nBuild with npm run build')).toBe(true)
  })
  it('detects system-reminder blocks', () => {
    expect(isPreambleContent('<system-reminder>\nYou have access to tools\n</system-reminder>')).toBe(true)
  })
  it('detects environment_context', () => {
    expect(isPreambleContent('<environment_context>\nOS: macOS\n</environment_context>')).toBe(true)
  })
  it('detects agents.md instructions', () => {
    expect(isPreambleContent('# agents.md instructions for Claude\nFollow these rules...')).toBe(true)
  })
  it('does NOT flag normal user messages', () => {
    expect(isPreambleContent('请帮我重构这个组件')).toBe(false)
  })
  it('does NOT flag short questions', () => {
    expect(isPreambleContent('What does this function do?')).toBe(false)
  })
  it('isPreambleOnly returns true when all messages are preamble', () => {
    expect(isPreambleOnly([
      'Contents of CLAUDE.md\n# Project',
      '<system-reminder>tools</system-reminder>'
    ])).toBe(true)
  })
  it('isPreambleOnly returns false when any message is real', () => {
    expect(isPreambleOnly([
      'Contents of CLAUDE.md',
      '请帮我重构这个组件'
    ])).toBe(false)
  })
})
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `npm test -- --run tests/preamble-detector.test.ts`

- [ ] **Step 3: Implement preamble-detector.ts**

```typescript
// src/core/preamble-detector.ts

const PREAMBLE_MARKERS = [
  'CLAUDE.md', 'AGENTS.md', 'GEMINI.md', '.cursorrules',
  'environment_context', 'system-reminder',
  '<instructions>', '</instructions>',
  '# agents.md instructions',
]

const SYSTEM_ROLE_PATTERNS = [
  /^you are an expert/i,
  /^your role is/i,
  /^system:/i,
  /^# System Instructions/i,
]

export function isPreambleContent(text: string): boolean {
  const prefix = text.slice(0, 2000)
  // Check markers
  if (PREAMBLE_MARKERS.some(m => prefix.includes(m))) return true
  // Check system role patterns
  if (SYSTEM_ROLE_PATTERNS.some(p => p.test(prefix))) return true
  // Check long markdown blocks (>6 lines with >4 heading/bullet lines)
  const lines = prefix.split('\n').slice(0, 20)
  if (lines.length >= 6) {
    const structuredLines = lines.filter(l => /^[#\-\*\d]/.test(l.trim()))
    if (structuredLines.length >= 4) return true
  }
  return false
}

export function isPreambleOnly(messages: string[]): boolean {
  if (messages.length === 0) return true
  return messages.every(m => isPreambleContent(m))
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `npm test -- --run tests/preamble-detector.test.ts`

- [ ] **Step 5: Commit**

`git commit -m "feat(tier): add preamble-detector for system injection detection"`

---

## Task 2: Enhance computeTier

**Files:** Modify: `src/core/session-tier.ts`, `tests/session-tier.test.ts`

- [ ] **Step 1: Write failing tests for new tier logic**

```typescript
// In tests/session-tier.test.ts — add these cases:
it('downgrades preamble-only to skip', () => {
  expect(computeTier({ ...base, messageCount: 5, isPreamble: true })).toBe('skip')
})
it('downgrades no-reply (0 assistant) to lite', () => {
  expect(computeTier({ ...base, messageCount: 3, assistantCount: 0, toolCount: 0 })).toBe('lite')
})
it('downgrades probe sessions to skip', () => {
  expect(computeTier({ ...base, messageCount: 2, filePath: '/Users/x/.engram/probes/claude/session.jsonl' })).toBe('skip')
})
it('does not downgrade normal conversations', () => {
  expect(computeTier({ ...base, messageCount: 5, isPreamble: false, assistantCount: 3 })).toBe('normal')
})
```

- [ ] **Step 2: Extend TierInput interface**

```typescript
interface TierInput {
  // existing fields...
  isPreamble?: boolean       // true if all user messages are preamble
  assistantCount?: number    // assistant message count
  toolCount?: number         // tool message count
}
```

- [ ] **Step 3: Enhance computeTier() logic**

Add before existing skip check:
```typescript
// Preamble-only → skip
if (input.isPreamble) return 'skip'
// Probe sessions (in probes directory) → skip
if (input.filePath?.includes('/.engram/probes/')) return 'skip'
// No-reply (has user messages but no AI response) → lite
if (input.messageCount > 0 && (input.assistantCount ?? 0) === 0 && (input.toolCount ?? 0) === 0) return 'lite'
```

- [ ] **Step 4: Run all tests**

Run: `npm test`

- [ ] **Step 5: Commit**

`git commit -m "feat(tier): enhance computeTier with preamble, no-reply, probe detection"`

---

## Task 3: Wire Preamble Detection into Indexer

**Files:** Modify: `src/core/indexer.ts`

- [ ] **Step 1: Extract firstUserMessages during indexing**

In the indexer's session processing loop, collect the first 3 user messages (up to 500 chars each) while streaming messages. Pass them through `isPreambleOnly()`.

- [ ] **Step 2: Pass isPreamble to computeTier**

```typescript
const firstUserMsgs = userMessages.slice(0, 3).map(m => m.content.slice(0, 500))
const isPreamble = isPreambleOnly(firstUserMsgs)
const tier = computeTier({ ...tierInput, isPreamble, assistantCount, toolCount })
```

- [ ] **Step 3: Run full test suite**

Run: `npm test`

- [ ] **Step 4: Commit**

`git commit -m "feat(tier): wire preamble detection into indexer pipeline"`

---

## Task 4: Backfill on Daemon Startup

**Files:** Modify: `src/daemon.ts` or `src/core/indexer.ts`

- [ ] **Step 1: Add backfill function**

On daemon startup (after initial index), re-compute tier for all sessions where `tier IS NULL OR tier IN ('normal', 'lite')`. This catches existing sessions that should now be downgraded.

- [ ] **Step 2: Test with real data**

Run daemon, check logs for "Backfill: N sessions re-tiered".

- [ ] **Step 3: Commit**

`git commit -m "feat(tier): backfill existing session tiers on daemon startup"`

---

## Task 5: Final Verification

- [ ] **Step 1: npm test — all pass**
- [ ] **Step 2: npm run build — no errors**
- [ ] **Step 3: Start daemon, verify preamble sessions are skip, no-reply are lite**
- [ ] **Step 4: In Engram app, verify noise filter hides newly-classified sessions**
- [ ] **Step 5: Final commit**

`git commit -m "feat(tier): PR4 complete — enhanced session housekeeping"`
