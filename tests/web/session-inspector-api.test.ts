import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { AiAuditWriter } from '../../src/core/ai-audit.js';
import { DEFAULT_AI_AUDIT_CONFIG } from '../../src/core/config.js';
import { Database } from '../../src/core/db.js';
import { createApp } from '../../src/web.js';

describe('GET /api/sessions/:id/inspect', () => {
  let db: Database;
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), 'session-inspector-api-'));
    db = new Database(join(tmpDir, 'test.sqlite'));
  });

  afterEach(() => {
    db.close();
    rmSync(tmpDir, { recursive: true, force: true });
  });

  function seedSession(overrides: Record<string, unknown> = {}) {
    db.getRawDb()
      .prepare(`
        INSERT INTO sessions (
          id, source, start_time, end_time, cwd, project, model,
          message_count, user_message_count, assistant_message_count,
          tool_message_count, system_message_count, summary,
          summary_message_count, file_path, size_bytes, tier,
          generated_title, indexed_at
        )
        VALUES (
          @id, @source, @startTime, @endTime, @cwd, @project, @model,
          @messageCount, @userMessageCount, @assistantMessageCount,
          @toolMessageCount, @systemMessageCount, @summary,
          @summaryMessageCount, @filePath, @sizeBytes, @tier,
          @generatedTitle, @indexedAt
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
        messageCount: 1,
        userMessageCount: 1,
        assistantMessageCount: 0,
        toolMessageCount: 0,
        systemMessageCount: 0,
        summary: 'seeded inspector session',
        summaryMessageCount: 1,
        filePath: '/Users/test/work/engram/.fixtures/sess-parent.jsonl',
        sizeBytes: 100,
        tier: 'normal',
        generatedTitle: 'Inspector smoke',
        indexedAt: '2026-05-07T08:31:00.000Z',
        ...overrides,
      });
  }

  it('returns 404 with fixed error JSON for missing session', async () => {
    const app = createApp(db);
    const res = await app.request('/api/sessions/missing/inspect');
    expect(res.status).toBe(404);
    const body = await res.json();
    expect(body).toEqual({ error: 'Session not found: missing' });
  });

  it('returns inspector DTO for an existing session', async () => {
    seedSession();

    const app = createApp(db);
    const res = await app.request('/api/sessions/sess-parent/inspect');
    expect(res.status).toBe(200);
    const body = await res.json();

    expect(body.session.id).toBe('sess-parent');
    expect(body.session.source).toBe('codex');
    expect(body.summaries.provenance).toHaveProperty('storedSummary');
    expect(body.summaries.storedSummary).toBe('seeded inspector session');
    expect(body.status).toHaveProperty('basisTags');
    expect(body.status.basisTags).toContain('has_end_time');
    expect(body.cost.source).toMatch(/engram_pricing|unknown/);
  });

  it('returns inspector DTO with cost source engram_pricing when costs exist', async () => {
    seedSession();
    db.upsertSessionCost('sess-parent', 'gpt-5.4', 200, 80, 0, 0, 0.25);

    const app = createApp(db);
    const res = await app.request('/api/sessions/sess-parent/inspect');
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.cost.source).toBe('engram_pricing');
    expect(body.cost.estimatedCostUsd).toBe(0.25);
  });

  it('does not invoke external CLI for resume — DTO has no command/args by default', async () => {
    seedSession();

    const app = createApp(db);
    const res = await app.request('/api/sessions/sess-parent/inspect');
    expect(res.status).toBe(200);
    const body = await res.json();

    // The route must call buildSessionInspector(db, id) with no resumeResolver,
    // so the resume DTO should be the safe unsupported shape (no command/args).
    expect(body.resume).toBeDefined();
    expect(body.resume.capability).toBe('unsupported');
    expect(body.resume.command).toBeUndefined();
    expect(body.resume.args).toBeUndefined();
    expect(body.resume.tool).toBe('codex');
    expect(body.resume.evidence).toBe('fallback');
  });

  it('exposes audit correlation and does not promote audit row to llmSummary', async () => {
    seedSession();
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
      durationMs: 10,
      sessionId: 'sess-parent',
      meta: { trigger: 'manual' },
    });

    const app = createApp(db);
    const res = await app.request('/api/sessions/sess-parent/inspect');
    expect(res.status).toBe(200);
    const body = await res.json();

    expect(body.llm.auditRecordCount).toBe(1);
    expect(body.llm.callers).toEqual(['summary']);
    expect(body.llm.trigger).toBe('manual');
    // Phase 0 invariant: an audit row alone must not back-fill llmSummary.
    expect(body.summaries.llmSummary).toBeUndefined();
    expect(body.summaries.provenance.llmSummary).toBe('unknown');
  });
});
