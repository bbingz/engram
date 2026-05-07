# LLM Session Inspector Harness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement a local-first session inspector harness that explains session facts, summary provenance, status, parent-child rollups, cost confidence, LLM audit correlation, and safe resume commands without calling external LLM providers from the inspector.

**Architecture:** Build the inspector as a pure TypeScript core builder first, using existing SQLite facts from `sessions`, `session_costs`, `session_tools`, parent links, `ai_audit_log`, and the resume coordinator. Add LLM audit correlation metadata in the existing audit table `meta` JSON before exposing the inspector through HTTP, then add MCP/golden and Swift UI as follow-up slices that consume the same contract instead of reimplementing it.

**Tech Stack:** TypeScript, Vitest, better-sqlite3, Hono web routes, existing MCP tool registry, existing MCP golden fixture generator, Swift 5.9/SwiftUI only after the TypeScript DTO is stable.

---

## Source Documents

- Spec: `docs/superpowers/specs/2026-05-07-llm-session-inspector-harness-design.md`
- Prior summary design: `docs/archive/superpowers/specs/2026-03-10-ai-summary-redesign.md`
- Parent-child design: `docs/archive/superpowers/specs/2026-04-13-agent-session-grouping-design.md`
- Project analytics cost contract: `docs/superpowers/specs/2026-05-06-project-analytics-dashboard-design.md`

## Execution Shape

Do not dispatch multiple implementation workers against the same files.

Recommended split:

- Worker 1: Task 1 only, owns `src/core/session-inspector.ts` plus DB read helpers and `tests/core/llm-inspector-harness.test.ts`.
- Worker 2: Task 2 only, owns summary/title/embedding audit context files and their tests.
- Worker 3: Task 3 only, owns `src/web.ts` route and web tests, after Task 1 lands.
- Worker 4: Task 4 only, owns MCP wrapper, `src/index.ts`, fixture generator, golden output, after Task 1 and Task 3 contract are stable.
- Worker 5: Task 5 was originally **BLOCKED** by the missing TypeScript-backed bridge in the Swift single-stack runtime. **Option A** was chosen and shipped as Swift-native inspector parity; the original "TypeScript-backed bridge" Steps 1–5 are preserved as historical context only. Task 6 (IPC/client hardening) shipped as a follow-up. Option C (Node/HTTP bridge inside the .app) was **not** adopted. See "Task 5: Swift Read-Only Inspector Surface — Option A shipped" below.

Before dispatching implementation workers, commit this spec and plan as a docs-only baseline or include both files in Worker 1's first docs commit. Downstream workers should implement against the committed plan/spec version, not against an untracked local draft.

Task dependencies:

- Task 1 is the base.
- Task 2 can run after Task 1 types are clear, but should not modify `session-inspector.ts`.
- Task 3 depends on Task 1.
- Task 4 depends on Tasks 1 and 3.
- Task 5 was originally **BLOCKED** by the missing TypeScript-backed bridge in the Swift single-stack runtime. **Option A** (Swift-native inspector parity) was chosen and completed; **Task 6** (IPC/client hardening) shipped as a follow-up. Option C (Node/HTTP bridge) was not adopted. Tasks 1–4 do not depend on Task 5.

## Files To Create Or Modify

Create:

- `src/core/session-inspector.ts`
- `tests/core/llm-inspector-harness.test.ts`
- `tests/fixtures/llm-inspector/session.json`
- `tests/fixtures/llm-inspector/expected-inspector/full-session.json`
- `tests/fixtures/llm-inspector/expected-inspector/missing-facts-session.json`
- `tests/fixtures/llm-inspector/expected-inspector/child-rollup-session.json`

Modify in Phase 0:

- `src/core/db/session-repo.ts`
- `src/core/db/metrics-repo.ts`
- `src/core/db/database.ts`
- `src/core/ai-audit.ts`
- `src/core/resume-coordinator.ts`
- `tests/core/resume-coordinator.test.ts`

Modify in Phase 1:

- `src/core/ai-client.ts`
- `src/core/title-generator.ts`
- `src/core/embeddings.ts`
- `src/core/indexer.ts`
- `src/core/index-job-runner.ts`
- `src/core/embedding-indexer.ts`
- `src/daemon.ts`
- `src/tools/generate_summary.ts`
- `src/web.ts`
- `tests/core/ai-client.test.ts`
- `tests/core/title-generator.test.ts`
- `tests/core/embeddings.test.ts`
- `tests/core/ai-audit.test.ts`
- `tests/core/index-job-runner.test.ts`
- `tests/core/embedding-indexer.test.ts`

Modify in Phase 2:

- `src/web.ts`
- `tests/web/session-inspector-api.test.ts`

Create or modify in Phase 3:

- `src/tools/inspect_session.ts`
- `src/index.ts`
- `scripts/gen-mcp-contract-fixtures.ts`
- `tests/tools/inspect_session.test.ts`
- `tests/fixtures/mcp-golden/README.md`
- `tests/fixtures/mcp-golden/session_inspector.fixture.json`

Swift Phase 4 — **shipped under Option A** (Swift-native inspector parity over the existing Unix-socket service path; no Node/HTTP bridge reintroduced). The files below were modified by Task 5 (Option A) plus the Task 6 hardening follow-up. The original three-way decision point between Option A, Option B (defer Swift panel), and Option C (re-bundle Node/HTTP bridge) is preserved as historical context in the Task 5 section.

- `macos/Engram/Views/SessionDetailView.swift`
- `macos/Shared/Service/EngramServiceModels.swift`
- `macos/Shared/Service/EngramServiceProtocol.swift`
- `macos/Shared/Service/EngramServiceClient.swift`
- `macos/Shared/Service/MockEngramServiceClient.swift`
- `macos/EngramService/Core/EngramServiceCommandHandler.swift`
- `macos/EngramService/Core/EngramServiceReadProvider.swift`

---

### Task 1: Core Session Inspector Builder

**Files:**

- Create: `src/core/session-inspector.ts`
- Create: `tests/core/llm-inspector-harness.test.ts`
- Create: `tests/fixtures/llm-inspector/session.json`
- Create: `tests/fixtures/llm-inspector/expected-inspector/full-session.json`
- Create: `tests/fixtures/llm-inspector/expected-inspector/missing-facts-session.json`
- Create: `tests/fixtures/llm-inspector/expected-inspector/child-rollup-session.json`
- Modify: `src/core/db/session-repo.ts`
- Modify: `src/core/db/metrics-repo.ts`
- Modify: `src/core/db/database.ts`
- Modify: `src/core/ai-audit.ts`
- Modify: `src/core/resume-coordinator.ts`
- Modify: `tests/core/resume-coordinator.test.ts`

- [ ] **Step 1: Write failing inspector tests**

Create `tests/core/llm-inspector-harness.test.ts` with a temporary `Database`, inserted session rows, inserted local state, child rows, cost rows, tool rows, and audit rows.

Use this test skeleton:

```ts
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { AiAuditQuery, AiAuditWriter } from '../../src/core/ai-audit.js';
import { Database } from '../../src/core/db.js';
import {
  buildResumeInspection,
  buildSessionInspector,
  deriveSessionStatus,
} from '../../src/core/session-inspector.js';
import { DEFAULT_AI_AUDIT_CONFIG } from '../../src/core/config.js';

describe('session inspector harness', () => {
  let db: Database;
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), 'session-inspector-'));
    db = new Database(join(tmpDir, 'test.sqlite'));
  });

  afterEach(() => {
    db.close();
    rmSync(tmpDir, { recursive: true, force: true });
  });

  function insertSession(overrides: Record<string, unknown> = {}) {
    db.getRawDb()
      .prepare(`
        INSERT INTO sessions (
          id, source, start_time, end_time, cwd, project, model,
          message_count, user_message_count, assistant_message_count,
          tool_message_count, system_message_count, summary,
          summary_message_count, file_path, size_bytes, tier, agent_role,
          parent_session_id, suggested_parent_id, link_source, generated_title,
          indexed_at
        )
        VALUES (
          @id, @source, @startTime, @endTime, @cwd, @project, @model,
          @messageCount, @userMessageCount, @assistantMessageCount,
          @toolMessageCount, @systemMessageCount, @summary,
          @summaryMessageCount, @filePath, @sizeBytes, @tier, @agentRole,
          @parentSessionId, @suggestedParentId, @linkSource, @generatedTitle,
          @indexedAt
        )
      `)
      .run({
        id: 'sess-parent',
        source: 'codex',
        startTime: '2026-05-07T08:00:00.000Z',
        endTime: '2026-05-07T08:30:00.000Z',
        cwd: '/Users/test/work/engram',
        project: 'engram',
        model: 'gpt-5.4',
        messageCount: 12,
        userMessageCount: 5,
        assistantMessageCount: 6,
        toolMessageCount: 1,
        systemMessageCount: 0,
        summary: 'Implemented session inspector contract',
        summaryMessageCount: 12,
        filePath: '/Users/test/work/engram/.fixtures/sess-parent.jsonl',
        sizeBytes: 1200,
        tier: 'normal',
        agentRole: null,
        parentSessionId: null,
        suggestedParentId: null,
        linkSource: null,
        generatedTitle: 'Inspector harness',
        indexedAt: '2026-05-07T08:31:00.000Z',
        ...overrides,
      });
  }

  it('returns null for a missing session', () => {
    expect(buildSessionInspector(db, 'missing')).toBeNull();
  });

  it('builds inspector facts without calling external providers', () => {
    insertSession();
    insertSession({
      id: 'child-1',
      source: 'codex',
      parentSessionId: 'sess-parent',
      linkSource: 'path',
      filePath: '/Users/test/work/engram/.fixtures/child-1.jsonl',
      summary: 'Child agent result',
      summaryMessageCount: null,
      tier: 'skip',
      agentRole: 'dispatched',
    });
    insertSession({
      id: 'suggested-1',
      source: 'gemini-cli',
      suggestedParentId: 'sess-parent',
      filePath: '/Users/test/work/engram/.fixtures/suggested-1.jsonl',
      summary: '<task> suggested child',
      summaryMessageCount: null,
      tier: 'skip',
      agentRole: 'dispatched',
    });

    db.getRawDb()
      .prepare(`
        INSERT INTO session_costs (
          session_id, model, input_tokens, output_tokens,
          cache_read_tokens, cache_creation_tokens, cost_usd, computed_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      `)
      .run('sess-parent', 'gpt-5.4', 100, 40, 10, 5, 0.0123, '2026-05-07T08:31:00.000Z');
    db.getRawDb()
      .prepare(`
        INSERT INTO session_costs (
          session_id, model, input_tokens, output_tokens,
          cache_read_tokens, cache_creation_tokens, cost_usd, computed_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      `)
      .run('child-1', 'gpt-5.4', 50, 25, 0, 0, 0.0042, '2026-05-07T08:31:00.000Z');

    const audit = new AiAuditWriter(db.getRawDb(), {
      ...DEFAULT_AI_AUDIT_CONFIG,
      enabled: true,
      logBodies: false,
    });
    audit.record({
      caller: 'summary',
      operation: 'summarize',
      provider: 'openai',
      model: 'gpt-5.4',
      promptTokens: 100,
      completionTokens: 30,
      totalTokens: 130,
      durationMs: 10,
      sessionId: 'sess-parent',
      meta: {
        trigger: 'manual',
        resolvedConfig: {
          preset: 'standard',
          maxTokens: 200,
          temperature: 0.3,
          sampleFirst: 20,
          sampleLast: 30,
          truncateChars: 500,
        },
      },
    });

    const result = buildSessionInspector(db, 'sess-parent', {
      now: new Date('2026-05-07T08:32:00.000Z'),
      resumeResolver: (cmd) => `/usr/local/bin/${cmd}`,
    });

    expect(result?.session.id).toBe('sess-parent');
    expect(result?.summaries.displayTitle).toBe('Inspector harness');
    expect(result?.summaries.storedSummary).toBe('Implemented session inspector contract');
    expect(result?.summaries.llmSummary).toBeUndefined();
    expect(result?.summaries.provenance.llmSummary).toBe('unknown');
    expect(result?.status.label).toBe('done');
    expect(result?.status.basisTags).toContain('has_end_time');
    expect(result?.agentGraph.childCount).toBe(1);
    expect(result?.agentGraph.suggestedChildCount).toBe(1);
    expect(result?.agentGraph.childRollup?.estimatedCostUsd).toBe(0.0042);
    expect(result?.cost.estimatedCostUsd).toBe(0.0123);
    expect(result?.llm.auditRecordCount).toBe(1);
    expect(result?.llm.callers).toEqual(['summary']);
    expect(result?.llm.resolvedSummaryConfig?.preset).toBe('standard');
    expect(result?.resume.tool).toBe('codex');
    expect(result?.resume.args).toEqual(['resume', 'sess-parent']);
  });
});
```

- [ ] **Step 2: Run the failing test**

Run:

```bash
npm run test -- tests/core/llm-inspector-harness.test.ts
```

Expected: fail because `src/core/session-inspector.ts` does not exist.

- [ ] **Step 3: Export the audit record type**

In `src/core/ai-audit.ts`, export `AiAuditRecord`:

```ts
export interface AiAuditRecord {
```

Do not change table schema.

- [ ] **Step 4: Add inspector DB helpers**

In `src/core/db/session-repo.ts`, add a helper that joins local state for `custom_name` and returns generated title and link fields:

```ts
export function getSessionInspectorSession(
  db: Database.Database,
  id: string,
): (SessionInfo & {
  customName?: string;
  generatedTitle?: string;
  linkSource?: 'path' | 'manual';
  indexedAt?: string;
}) | null {
  const row = db
    .prepare(`
      SELECT s.*, ls.custom_name
      FROM sessions s
      LEFT JOIN session_local_state ls ON ls.session_id = s.id
      WHERE s.id = ?
    `)
    .get(id) as Record<string, unknown> | undefined;
  if (!row) return null;
  const session = rowToSession(row);
  return {
    ...session,
    customName: (row.custom_name as string | null) ?? undefined,
    generatedTitle: (row.generated_title as string | null) ?? undefined,
    linkSource: (row.link_source as 'path' | 'manual' | null) ?? undefined,
    indexedAt: (row.indexed_at as string | null) ?? undefined,
  };
}
```

If `rowToSession` is not exported in the file, keep the helper inside `session-repo.ts` and reuse the local mapper there.

In `src/core/db/metrics-repo.ts`, add:

```ts
export interface SessionCostRow {
  inputTokens: number;
  outputTokens: number;
  cacheReadTokens: number;
  cacheCreationTokens: number;
  costUsd: number;
  model: string | null;
}

export function getSessionCost(
  db: Database.Database,
  sessionId: string,
): SessionCostRow | null {
  const row = db
    .prepare(`
      SELECT input_tokens, output_tokens, cache_read_tokens,
             cache_creation_tokens, cost_usd, model
      FROM session_costs
      WHERE session_id = ?
    `)
    .get(sessionId) as
    | {
        input_tokens: number | null;
        output_tokens: number | null;
        cache_read_tokens: number | null;
        cache_creation_tokens: number | null;
        cost_usd: number | null;
        model: string | null;
      }
    | undefined;
  if (!row) return null;
  return {
    inputTokens: row.input_tokens ?? 0,
    outputTokens: row.output_tokens ?? 0,
    cacheReadTokens: row.cache_read_tokens ?? 0,
    cacheCreationTokens: row.cache_creation_tokens ?? 0,
    costUsd: row.cost_usd ?? 0,
    model: row.model,
  };
}

export function getChildCostRollup(
  db: Database.Database,
  parentId: string,
): { tokenTotal: number; estimatedCostUsd: number } | null {
  const row = db
    .prepare(`
      SELECT
        COALESCE(SUM(c.input_tokens), 0) +
        COALESCE(SUM(c.output_tokens), 0) +
        COALESCE(SUM(c.cache_read_tokens), 0) +
        COALESCE(SUM(c.cache_creation_tokens), 0) AS tokenTotal,
        COALESCE(SUM(c.cost_usd), 0) AS estimatedCostUsd
      FROM sessions s
      JOIN session_costs c ON c.session_id = s.id
      WHERE s.parent_session_id = ?
    `)
    .get(parentId) as { tokenTotal: number; estimatedCostUsd: number } | undefined;
  if (!row || (row.tokenTotal === 0 && row.estimatedCostUsd === 0)) return null;
  return row;
}
```

In `src/core/db/database.ts`, add facade methods for these helpers.

- [ ] **Step 5: Implement the session inspector builder**

Create `src/core/session-inspector.ts` with exported DTO types and these functions:

```ts
import type { Database } from './db.js';
import { buildResumeCommand } from './resume-coordinator.js';

export type SessionStatusLabel =
  | 'done'
  | 'in_progress'
  | 'waiting'
  | 'errored'
  | 'abandoned'
  | 'unknown';

export type SummaryProvenance =
  | 'adapter_first_message'
  | 'engram_llm_manual'
  | 'engram_llm_auto'
  | 'upstream_compact'
  | 'fallback'
  | 'unknown';

export type DerivedFieldProvenance =
  | 'database'
  | 'ai_audit'
  | 'source_transcript'
  | 'rule'
  | 'heuristic'
  | 'fallback'
  | 'unknown';

export interface SessionInspector {
  session: {
    id: string;
    source: string;
    project?: string;
    cwd?: string;
    model?: string;
    startTime?: string;
    endTime?: string;
    messageCount: number;
    filePath?: string;
    tier?: 'skip' | 'lite' | 'normal' | 'premium';
    agentRole?: string;
  };
  provenance: {
    transcript: 'local_file' | 'database_snapshot' | 'missing';
    title: DerivedFieldProvenance;
    cost: DerivedFieldProvenance;
    parentLink: DerivedFieldProvenance;
  };
  summaries: {
    displayTitle?: string;
    firstMessageSummary?: string;
    storedSummary?: string;
    llmSummary?: string;
    compactSummary?: string;
    summaryMessageCount?: number;
    isSummaryStale?: boolean;
    provenance: {
      firstMessageSummary: SummaryProvenance;
      storedSummary: SummaryProvenance;
      llmSummary: SummaryProvenance;
      compactSummary: SummaryProvenance;
    };
  };
  status: {
    label: SessionStatusLabel;
    confidence: 'high' | 'medium' | 'low';
    source: 'rule' | 'live_probe' | 'llm' | 'fallback' | 'unknown';
    basisTags: string[];
    observedAt?: string;
  };
  agentGraph: {
    parentSessionId?: string;
    suggestedParentId?: string;
    linkSource?: 'path' | 'manual';
    childCount: number;
    suggestedChildCount: number;
    childRollup?: {
      sources: Record<string, number>;
      tokenTotal?: number;
      estimatedCostUsd?: number;
    };
  };
  llm: {
    auditRecordCount: number;
    lastAuditAt?: string;
    callers: Array<'summary' | 'title' | 'embedding'>;
    lastError?: string;
    promptVersion?: string;
    resolvedSummaryConfig?: {
      preset?: string;
      maxTokens: number;
      temperature: number;
      sampleFirst: number;
      sampleLast: number;
      truncateChars: number;
    };
    trigger?: 'manual' | 'auto' | 'indexing' | 'unknown';
  };
  resume: {
    capability: 'supported' | 'legacy' | 'fallback' | 'unsupported';
    tool?: string;
    command?: string;
    args?: string[];
    cwd?: string;
    evidence: 'official_doc' | 'local_help' | 'observed_jsonl' | 'heuristic' | 'fallback';
    warning?: string;
  };
  cost: {
    inputTokens?: number;
    outputTokens?: number;
    cacheReadTokens?: number;
    cacheCreationTokens?: number;
    estimatedCostUsd?: number;
    source: 'engram_pricing' | 'provider_reported' | 'unknown';
    pricedCoverage?: number;
    unknownModelCount?: number;
    warning?: string;
  };
}
```

Implementation rules:

- `buildSessionInspector()` returns `null` for missing sessions.
- It must not call `fetch`, adapter message streaming, or external CLIs.
- It may call DB facade reads and `buildResumeInspection()`.
- It must normalize audit callers: `summary -> summary`, `title -> title`, `embedding | semantic_index | memory -> embedding`.
- It must keep parent cost and child cost separate.
- It must treat `sessions.summary` as `summaries.storedSummary`, preserving `summaryMessageCount` and marking `summaries.provenance.storedSummary` from database evidence.
- It must not populate `summaries.llmSummary` from `sessions.summary` merely because a summary audit row exists. Current `ai_audit_log` rows record request/config metadata but not a durable response-body link; keep `llmSummary` absent and `summaries.provenance.llmSummary = 'unknown'` unless a future persisted provenance field proves the exact summary text came from Engram LLM.
- Summary audit rows may populate `llm.auditRecordCount`, `llm.callers`, `llm.resolvedSummaryConfig`, and `llm.trigger`; they are correlation evidence, not summary text provenance.

- [ ] **Step 6: Fix Codex resume command**

In `src/core/resume-coordinator.ts`, change the Codex command from `['--resume', sessionId]` to `['resume', sessionId]`.

Add an exported pure helper for inspector use:

```ts
export function buildResumeInspection(
  source: string,
  sessionId: string,
  cwd: string,
  opts?: { resolveCommand?: (cmd: string) => string | null },
): SessionInspector['resume'] {
  // import type only or define a local compatible return shape if needed
}
```

If importing `SessionInspector` would create a cycle, define a local `ResumeInspection` interface in `resume-coordinator.ts` and re-export it.

- [ ] **Step 7: Update resume tests**

In `tests/core/resume-coordinator.test.ts`, update the Codex assertion:

```ts
expect(result.args).toEqual(['resume', 'session-xyz']);
expect(result.args).not.toContain('--resume');
```

Add a pure resolver test that does not depend on `which codex` being installed:

```ts
const result = buildResumeInspection('codex', 'session-xyz', '/some/dir', {
  resolveCommand: (cmd) => `/mock/bin/${cmd}`,
});
expect(result.capability).toBe('supported');
expect(result.command).toBe('/mock/bin/codex');
expect(result.args).toEqual(['resume', 'session-xyz']);
```

- [ ] **Step 8: Verify Phase 0**

Run:

```bash
npm run test -- tests/core/llm-inspector-harness.test.ts tests/core/resume-coordinator.test.ts tests/core/ai-audit.test.ts tests/core/db/metrics-repo.test.ts tests/core/db/parent-link-repo.test.ts
npm run build
npm run lint
```

Expected: all pass.

Commit:

```bash
git add src/core/session-inspector.ts src/core/db/session-repo.ts src/core/db/metrics-repo.ts src/core/db/database.ts src/core/ai-audit.ts src/core/resume-coordinator.ts tests/core/llm-inspector-harness.test.ts tests/core/resume-coordinator.test.ts tests/fixtures/llm-inspector/session.json tests/fixtures/llm-inspector/expected-inspector/full-session.json tests/fixtures/llm-inspector/expected-inspector/missing-facts-session.json tests/fixtures/llm-inspector/expected-inspector/child-rollup-session.json
git commit -m "feat: add session inspector builder"
```

---

### Task 2: LLM Audit Correlation Metadata

**Files:**

- Modify: `src/core/ai-client.ts`
- Modify: `src/core/title-generator.ts`
- Modify: `src/core/embeddings.ts`
- Modify: `src/core/indexer.ts`
- Modify: `src/core/index-job-runner.ts`
- Modify: `src/core/embedding-indexer.ts`
- Modify: `src/daemon.ts`
- Modify: `src/tools/generate_summary.ts`
- Modify: `src/web.ts`
- Modify: `tests/core/ai-client.test.ts`
- Modify: `tests/core/title-generator.test.ts`
- Modify: `tests/core/embeddings.test.ts`
- Modify: `tests/core/ai-audit.test.ts`
- Modify: `tests/core/index-job-runner.test.ts`
- Modify: `tests/core/embedding-indexer.test.ts`

- [ ] **Step 1: Add failing summary audit assertions**

In `tests/core/ai-client.test.ts`, extend the existing OpenAI summary audit success test to assert:

```ts
expect(entry.meta).toMatchObject({
  trigger: 'manual',
  messageCount: 2,
  sampledMessageCount: 2,
  resolvedConfig: {
    maxTokens: 200,
    temperature: 0.3,
    sampleFirst: 20,
    sampleLast: 30,
    truncateChars: 500,
  },
});
```

Update the call to pass:

```ts
{ audit: audit as any, sessionId: 'sess-1', trigger: 'manual' }
```

Add the same `meta.trigger` and `sessionId` expectations to error and network failure tests.

- [ ] **Step 2: Implement summary audit meta**

In `src/core/ai-client.ts`, introduce:

```ts
export type LlmAuditTrigger = 'manual' | 'auto' | 'indexing' | 'unknown';

interface SummaryAuditOptions {
  audit?: AiAuditWriter;
  sessionId?: string;
  trigger?: LlmAuditTrigger;
}
```

Change `summarizeConversation()` opts to `SummaryAuditOptions`.

Build this meta once and pass it to every `opts?.audit?.record()` call:

```ts
const auditMeta = {
  trigger: opts?.trigger ?? 'unknown',
  messageCount: messages.length,
  sampledMessageCount: sampled.length,
  resolvedConfig: {
    maxTokens: summaryConfig.maxTokens,
    temperature: summaryConfig.temperature,
    sampleFirst: summaryConfig.sampleFirst,
    sampleLast: summaryConfig.sampleLast,
    truncateChars: summaryConfig.truncateChars,
  },
};
```

- [ ] **Step 3: Pass summary triggers from call sites**

Update call sites:

```ts
// src/tools/generate_summary.ts
trigger: 'manual'

// src/web.ts /api/summary
trigger: 'manual'

// src/daemon.ts auto-summary
trigger: 'auto'
```

- [ ] **Step 4: Add title audit context tests**

In `tests/core/title-generator.test.ts`, add a test that calls:

```ts
await generator.generate(messages, {
  sessionId: 'sess-title',
  trigger: 'indexing',
});
```

Assert audit record includes:

```ts
expect(entry.sessionId).toBe('sess-title');
expect(entry.meta).toMatchObject({ trigger: 'indexing' });
```

- [ ] **Step 5: Implement title audit context**

In `src/core/title-generator.ts`, add:

```ts
interface TitleGenerateOptions {
  sessionId?: string;
  trigger?: LlmAuditTrigger;
}
```

Change:

```ts
async generate(messages: { role: string; content: string }[], opts?: TitleGenerateOptions)
```

Pass `opts` into `callLLM(prompt, opts)`, and include `sessionId` plus `meta: { trigger: opts?.trigger ?? 'unknown' }` in both success and error audit records.

In `src/core/indexer.ts`, call:

```ts
await titleGenerator.generate(messages, {
  sessionId: info.id,
  trigger: 'indexing',
});
```

- [ ] **Step 6: Add embedding audit context tests**

In `tests/core/embeddings.test.ts`, update one Ollama or OpenAI success test to call:

```ts
await client.embed('hello', {
  sessionId: 'sess-embed',
  textKind: 'chunk',
  chunkIndex: 3,
});
```

Assert:

```ts
expect(entry.sessionId).toBe('sess-embed');
expect(entry.meta).toMatchObject({
  textKind: 'chunk',
  chunkIndex: 3,
});
```

- [ ] **Step 7: Implement embedding context**

In `src/core/embeddings.ts`, add:

```ts
export interface EmbeddingAuditContext {
  sessionId?: string;
  textKind?: 'session' | 'chunk' | 'insight' | 'query';
  chunkId?: string;
  chunkIndex?: number;
}
```

Change `embed(text: string)` to `embed(text: string, context?: EmbeddingAuditContext)`.

In all audit records, include:

```ts
sessionId: context?.sessionId,
meta: {
  ...(existingMeta ?? {}),
  textKind: context?.textKind,
  chunkId: context?.chunkId,
  chunkIndex: context?.chunkIndex,
}
```

Keep the second argument optional so old call sites remain valid.

- [ ] **Step 8: Pass embedding context from indexers**

In `src/core/index-job-runner.ts` and `src/core/embedding-indexer.ts`, pass `sessionId`, `textKind: 'chunk'`, and `chunkIndex` where chunking is available. For session-level embedding, use `textKind: 'session'`.

If existing mocks fail because they accept one argument, update only the test mocks to accept a second optional parameter.

- [ ] **Step 9: Verify Phase 1**

Run:

```bash
npm run test -- tests/core/ai-client.test.ts tests/core/title-generator.test.ts tests/core/embeddings.test.ts tests/core/ai-audit.test.ts tests/core/index-job-runner.test.ts tests/core/embedding-indexer.test.ts
npm run build
npm run lint
```

Expected: all pass.

Commit:

```bash
git add src/core/ai-client.ts src/core/title-generator.ts src/core/embeddings.ts src/core/indexer.ts src/core/index-job-runner.ts src/core/embedding-indexer.ts src/daemon.ts src/tools/generate_summary.ts src/web.ts tests/core/ai-client.test.ts tests/core/title-generator.test.ts tests/core/embeddings.test.ts tests/core/ai-audit.test.ts tests/core/index-job-runner.test.ts tests/core/embedding-indexer.test.ts
git commit -m "feat: correlate llm audit records"
```

---

### Task 3: HTTP Inspector Endpoint

**Files:**

- Modify: `src/web.ts`
- Create: `tests/web/session-inspector-api.test.ts`

- [ ] **Step 1: Write failing API tests**

Create `tests/web/session-inspector-api.test.ts` using the existing `createApp()` test pattern from `tests/web/ai-audit-api.test.ts` and `tests/web/server.test.ts`.

Test cases:

```ts
it('returns 404 for a missing session inspector request', async () => {
  const res = await app.request('/api/sessions/missing/inspect');
  expect(res.status).toBe(404);
  expect(await res.json()).toEqual({ error: 'Session not found: missing' });
});

it('returns inspector dto for an existing session', async () => {
  db.upsertSession({
    id: 'sess-parent',
    source: 'codex',
    startTime: '2026-05-07T08:00:00.000Z',
    endTime: '2026-05-07T08:30:00.000Z',
    cwd: '/Users/test/work/engram',
    project: 'engram',
    model: 'gpt-5.4',
    messageCount: 1,
    userMessageCount: 1,
    assistantMessageCount: 0,
    toolMessageCount: 0,
    systemMessageCount: 0,
    filePath: '/Users/test/work/engram/.fixtures/sess-parent.jsonl',
    sizeBytes: 100,
    summary: 'seeded inspector session',
  });

  const res = await app.request('/api/sessions/sess-parent/inspect');
  expect(res.status).toBe(200);
  const body = await res.json();
  expect(body.session.id).toBe('sess-parent');
  expect(body.summaries.provenance).toHaveProperty('storedSummary');
  expect(body.status).toHaveProperty('basisTags');
  expect(body.cost.source).toMatch(/engram_pricing|unknown/);
});
```

- [ ] **Step 2: Add the route**

In `src/web.ts`, import:

```ts
import { buildSessionInspector } from './core/session-inspector.js';
```

Near the existing session detail, children, timeline, and resume routes, add:

```ts
app.get('/api/sessions/:id/inspect', (c) => {
  const sessionId = c.req.param('id');
  const inspector = buildSessionInspector(db, sessionId);
  if (!inspector) {
    return c.json({ error: `Session not found: ${sessionId}` }, 404);
  }
  return c.json(inspector);
});
```

Do not call external providers. Do not mutate DB.

- [ ] **Step 3: Verify Phase 2**

Run:

```bash
npm run test -- tests/core/llm-inspector-harness.test.ts tests/web/session-inspector-api.test.ts tests/web/ai-audit-api.test.ts
npm run build
npm run lint
```

Expected: all pass.

Commit:

```bash
git add src/web.ts tests/web/session-inspector-api.test.ts
git commit -m "feat: expose session inspector api"
```

---

### Task 4: MCP Inspector Tool And Golden Fixture

**Files:**

- Create: `src/tools/inspect_session.ts`
- Modify: `src/index.ts`
- Create: `tests/tools/inspect_session.test.ts`
- Modify: `scripts/gen-mcp-contract-fixtures.ts`
- Modify: `tests/fixtures/mcp-golden/README.md`
- Create: `tests/fixtures/mcp-golden/session_inspector.fixture.json`

- [ ] **Step 1: Write tool handler tests**

Create `tests/tools/inspect_session.test.ts`:

```ts
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { Database } from '../../src/core/db.js';
import { handleInspectSession } from '../../src/tools/inspect_session.js';

describe('inspect_session', () => {
  let db: Database;
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), 'inspect-session-tool-'));
    db = new Database(join(tmpDir, 'test.sqlite'));
  });

  afterEach(() => {
    db.close();
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it('returns MCP error for a missing session', async () => {
    const result = await handleInspectSession(db, { id: 'missing' });
    expect(result.isError).toBe(true);
    expect(result.content[0].text).toContain('Session not found');
  });
});
```

- [ ] **Step 2: Implement the tool**

Create `src/tools/inspect_session.ts`:

```ts
import { buildSessionInspector } from '../core/session-inspector.js';
import type { Database } from '../core/db.js';

export const inspectSessionTool = {
  name: 'inspect_session',
  description:
    'Inspect derived facts, provenance, status, cost, parent/child rollup, LLM audit, and resume command for one session.',
  inputSchema: {
    type: 'object' as const,
    required: ['id'],
    properties: {
      id: { type: 'string', description: 'Session ID' },
    },
    additionalProperties: false,
  },
};

export async function handleInspectSession(
  db: Database,
  params: { id: string },
) {
  const inspector = buildSessionInspector(db, params.id);
  if (!inspector) {
    return {
      content: [
        { type: 'text' as const, text: `Session not found: ${params.id}` },
      ],
      isError: true,
    };
  }
  return {
    content: [
      { type: 'text' as const, text: JSON.stringify(inspector, null, 2) },
    ],
  };
}
```

- [ ] **Step 3: Register the MCP tool**

In `src/index.ts`:

```ts
import {
  inspectSessionTool,
  handleInspectSession,
} from './tools/inspect_session.js';
```

Add `inspectSessionTool` immediately after `getSessionTool` in `allTools`.

Add:

```ts
toolRegistry.set('inspect_session', async (a) => ({
  _early: true,
  ...(await handleInspectSession(db, a as { id: string })),
}));
```

- [ ] **Step 4: Add MCP golden**

Update `scripts/gen-mcp-contract-fixtures.ts` to seed one inspector-ready session with:

- session row
- cost row
- child row
- suggested child row
- one `ai_audit_log` row with redacted or no body

Add a `session_inspector.fixture` golden by invoking `handleInspectSession()`.

Update `tests/fixtures/mcp-golden/README.md` to add:

```md
- inspector fixtures normalize trace IDs, durations, temp paths, and generated IDs
- provider secrets, Authorization headers, Gemini URL keys, and secret-like body values must be redacted before entering golden output
- inspector output must not require a real LLM provider or `~/.engram/index.sqlite`
```

- [ ] **Step 5: Verify Phase 3**

Run:

```bash
npm run test -- tests/tools/inspect_session.test.ts tests/core/llm-inspector-harness.test.ts
npm run generate:mcp-contract-fixtures
npm run test -- tests/tools
npm run build
npm run lint
```

Expected: all pass.

Commit:

```bash
git add src/tools/inspect_session.ts src/index.ts tests/tools/inspect_session.test.ts scripts/gen-mcp-contract-fixtures.ts tests/fixtures/mcp-golden/README.md tests/fixtures/mcp-golden/session_inspector.fixture.json
git commit -m "feat: add inspect session mcp tool"
```

---

### Task 5: Swift Read-Only Inspector Surface — Option A shipped

**Status:** Completed under **Option A** (Swift-native inspector parity over the existing Unix-socket service path). The original "TypeScript-backed bridge" Steps 1–5 are preserved below as historical context only. Task 6 (IPC/client hardening) shipped as a follow-up. **Option C** (re-bundle Node/HTTP bridge inside the .app) was **not** adopted.

**History — original block (preserved as context)**

Task 5 step 2 originally required: "route the request to the same TypeScript-backed inspector contract exposed by Task 3, or defer Task 5 until that service bridge exists. Do not recreate inspector derivation from Swift-only SQLite reads in this slice."

That bridge does not exist in the shipped macOS app:

- `EngramServiceLauncher` (`macos/Engram/Core/EngramServiceLauncher.swift`) launches `Contents/Helpers/EngramService` — a Swift-native helper, not a Node process.
- `EngramServiceRunner.run()` (`macos/EngramService/Core/EngramServiceRunner.swift`) wires up `UnixSocketServiceServer` + `ServiceWriterGate` + `SQLiteEngramServiceReadProvider`. There is no `Process()` for `node`, no HTTP listener, no port advertisement.
- The `web_ready` event handling in `EngramServiceStatusStore.apply` and `IndexerProcess.swift` is dead under the current architecture: `IndexerProcess` is not instantiated anywhere in the running app, and only the legacy `src/daemon.ts:emit({event: 'web_ready', ...})` path (no longer launched by the app) ever produced that event.
- Stage 5 single-stack verification removed the Node bundle build step, the `macos/scripts/build-node-bundle.sh` invocation, and the `Contents/Resources/node/...` artifacts from the `.app`. The auto-memory note `macos-app-architecture.md` records this: "Swift-native runtime; TS `src/` does NOT ship inside the .app; CLAUDE.md's node-bundle section is stale."

Three options were considered (A: Swift-native parity, B: defer the Swift panel, C: re-bundle Node/HTTP bridge). The user selected **Option A**.

**Final status — Option A implementation**

Task 5 (Option A) was implemented as Swift-native inspector parity over the existing Unix-socket service path:

- `EngramServiceSessionInspector` DTO under `macos/Shared/Service/EngramServiceModels.swift` mirrors the TypeScript `SessionInspector` contract (session/provenance/summaries/status/agentGraph/llm/resume/cost) and is `Codable`/`Sendable`.
- `inspectSession(id:)` is wired through `EngramServiceClientProtocol`, `EngramServiceClient`, `MockEngramServiceClient`, the IPC `EngramServiceCommandHandler`, and the read-provider hierarchy. `SQLiteEngramServiceReadProvider.inspectSession(_:)` derives the DTO via GRDB read-only queries; `EmptyEngramServiceReadProvider`/`FileSystemEngramServiceReadProvider` reject missing sessions with `EngramServiceError.invalidRequest`.
- `SessionDetailView` carries a compact `SessionInspectorPanel` rendered below the transcript (status, title, summary provenance, llm audit metadata, cost source/warning, child count/rollup, resume capability), with `accessibilityIdentifier("detail_inspector")` on success and `"detail_inspector_error"` on error. `loadInspector()` clears prior state up front and guards against the session id changing during the in-flight await so switching sessions cannot show stale data.
- Coverage: `EngramServiceCoreTests/EngramServiceInspectorTests.swift` (provider-level, 6 tests including contract-golden decoding of `tests/fixtures/mcp-golden/session_inspector.fixture.json`); Task 6 added `EngramServiceCoreTests/EngramServiceInspectorClientTests.swift` (client encoding/decoding, 2 tests) and `EngramServiceIPCTests/testInspectSessionRoundtripDecodesInspectorDTO` + `testInspectSessionMissingSessionPropagatesInvalidRequest` (real Unix-socket round trip, 2 tests).

**Guardrails preserved (still active)**

- No Node, no `daemon.js`, no `build-node-bundle`, no HTTP bridge, no `URLSession` forwarding, no `Process()` invocation, and no `which` lookup inside the inspector code paths (`macos/Shared/Service`, `macos/EngramService/Core/EngramServiceReadProvider.swift`'s inspector method, `macos/Engram/Views/SessionDetailView.swift`).
- `summaries.llmSummary` remains absent (`nil`/`"unknown"`) even when `ai_audit_log` rows exist — audit metadata populates `llm.auditRecordCount`/`callers`/`trigger`/`resolvedSummaryConfig` only.
- Parent cost stays parent-scoped (`session_costs WHERE session_id = ?`); confirmed child rollup is `JOIN session_costs ON c.session_id = s.id WHERE s.parent_session_id = ?` and excludes suggested-only children.
- Resume defaults to `capability: "unsupported"` with no `command`/`args` for known CLI sources (codex/claude-code/gemini-cli) — no PATH probing in the inspector path.
- Codex resume shape stays `['resume', sessionId]`; the Swift inspector reuses the TypeScript shape via the contract-golden parity test rather than re-deriving it.
- TypeScript `SessionInspector` and Swift `EngramServiceSessionInspector` are intentionally parallel implementations; `tests/fixtures/mcp-golden/session_inspector.fixture.json` is the single source of truth, enforced by the Swift parity test.

**Files modified for Option A + Task 6 hardening**

- `macos/Engram/Views/SessionDetailView.swift`
- `macos/Shared/Service/EngramServiceModels.swift`
- `macos/Shared/Service/EngramServiceProtocol.swift`
- `macos/Shared/Service/EngramServiceClient.swift`
- `macos/Shared/Service/MockEngramServiceClient.swift`
- `macos/EngramService/Core/EngramServiceCommandHandler.swift`
- `macos/EngramService/Core/EngramServiceReadProvider.swift`
- `macos/EngramServiceCoreTests/EngramServiceInspectorTests.swift` (new, Task 5 Option A)
- `macos/EngramServiceCoreTests/EngramServiceInspectorClientTests.swift` (new, Task 6)
- `macos/EngramServiceCoreTests/EngramServiceIPCTests.swift` (extended for Task 6 IPC roundtrip)

**Future work (out of scope)**

Option C (Node/HTTP bridge inside the .app) is not adopted. If a future milestone wants to re-share derivation between TypeScript and Swift, that is a separate "Service Bridge to TypeScript Inspector" slice and requires explicit re-approval of bundling Node into the .app.

---

## Final Verification

After all selected tasks land, run:

```bash
npm run test -- tests/core/llm-inspector-harness.test.ts tests/core/ai-client.test.ts tests/core/title-generator.test.ts tests/core/embeddings.test.ts tests/core/ai-audit.test.ts tests/core/resume-coordinator.test.ts tests/web/session-inspector-api.test.ts tests/tools/inspect_session.test.ts
npm run generate:mcp-contract-fixtures
npm run test -- tests/tools tests/web/ai-audit-api.test.ts
npm run build
npm run lint
```

Task 5 (Option A) and the Task 6 hardening follow-up are both completed; the Swift verification below is a required part of the closeout matrix.

```bash
cd macos && xcodegen generate
xcodebuild -project Engram.xcodeproj -scheme EngramServiceCore -configuration Debug -derivedDataPath /tmp/engram-inspector-service-dd build
xcodebuild -project Engram.xcodeproj -scheme EngramServiceCore -configuration Debug -derivedDataPath /tmp/engram-inspector-service-dd test \
  -only-testing:EngramServiceCoreTests/EngramServiceInspectorTests \
  -only-testing:EngramServiceCoreTests/EngramServiceInspectorClientTests \
  -only-testing:EngramServiceCoreTests/EngramServiceIPCTests/testInspectSessionRoundtripDecodesInspectorDTO \
  -only-testing:EngramServiceCoreTests/EngramServiceIPCTests/testInspectSessionMissingSessionPropagatesInvalidRequest
xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug -derivedDataPath /tmp/engram-inspector-app-dd build
```

## Self-Review Checklist

- [ ] No real LLM provider calls are required in tests.
- [ ] No test reads or writes `~/.engram/index.sqlite`.
- [ ] `get_session` remains transcript pagination, not inspector output.
- [ ] `generate_summary` remains a write operation, not inspector output.
- [ ] Child agent costs are separate from parent primary cost.
- [ ] `summary` provenance is per summary-like field, not one generic source.
- [ ] Codex resume uses `codex resume <SESSION_ID>` in any slice that touches resume output.
- [ ] `ai_audit_log.meta` is used before adding schema.
- [ ] Body logging remains disabled by default.
- [ ] Public golden output is normalized and redacted.
