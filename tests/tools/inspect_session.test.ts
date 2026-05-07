// tests/tools/inspect_session.test.ts

import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { AiAuditWriter } from '../../src/core/ai-audit.js';
import { DEFAULT_AI_AUDIT_CONFIG } from '../../src/core/config.js';
import { Database } from '../../src/core/db.js';
import {
  handleInspectSession,
  inspectSessionTool,
} from '../../src/tools/inspect_session.js';

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
        id: 'sess-mcp',
        source: 'codex',
        startTime: '2026-05-07T08:00:00.000Z',
        endTime: '2026-05-07T08:30:00.000Z',
        cwd: '/Users/test/work/engram',
        project: 'engram',
        model: 'gpt-5.4',
        messageCount: 6,
        userMessageCount: 3,
        assistantMessageCount: 3,
        toolMessageCount: 0,
        systemMessageCount: 0,
        summary: 'mcp inspector smoke',
        summaryMessageCount: 6,
        filePath: '/Users/test/work/engram/.fixtures/sess-mcp.jsonl',
        sizeBytes: 256,
        tier: 'normal',
        generatedTitle: 'Inspector smoke',
        indexedAt: '2026-05-07T08:31:00.000Z',
        ...overrides,
      });
  }

  it('exposes the expected MCP tool schema', () => {
    expect(inspectSessionTool.name).toBe('inspect_session');
    expect(inspectSessionTool.inputSchema.type).toBe('object');
    expect(inspectSessionTool.inputSchema.required).toEqual(['id']);
    expect(inspectSessionTool.inputSchema.additionalProperties).toBe(false);
    expect(inspectSessionTool.inputSchema.properties).toHaveProperty('id');
  });

  it('returns MCP error shape for a missing session', async () => {
    const result = await handleInspectSession(db, { id: 'missing' });
    expect(result.isError).toBe(true);
    expect(result.content).toHaveLength(1);
    expect(result.content[0].type).toBe('text');
    expect(result.content[0].text).toContain('Session not found');
    expect(result.content[0].text).toContain('missing');
  });

  it('returns the inspector DTO as JSON for an existing session', async () => {
    seedSession();

    const result = await handleInspectSession(db, { id: 'sess-mcp' });
    expect(result.isError).toBeUndefined();
    expect(result.content).toHaveLength(1);
    expect(result.content[0].type).toBe('text');

    const parsed = JSON.parse(result.content[0].text);
    expect(parsed.session.id).toBe('sess-mcp');
    expect(parsed.session.source).toBe('codex');
    expect(parsed.summaries.storedSummary).toBe('mcp inspector smoke');
    expect(parsed.status.basisTags).toContain('has_end_time');
  });

  it('does not invoke external CLI for resume — DTO has no command/args by default', async () => {
    seedSession();

    const result = await handleInspectSession(db, { id: 'sess-mcp' });
    const parsed = JSON.parse(result.content[0].text);
    expect(parsed.resume.capability).toBe('unsupported');
    expect(parsed.resume.tool).toBe('codex');
    expect(parsed.resume.command).toBeUndefined();
    expect(parsed.resume.args).toBeUndefined();
    expect(parsed.resume.evidence).toBe('fallback');
  });

  it('exposes audit correlation but never back-fills llmSummary from an audit row', async () => {
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
      durationMs: 12,
      sessionId: 'sess-mcp',
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

    const result = await handleInspectSession(db, { id: 'sess-mcp' });
    const parsed = JSON.parse(result.content[0].text);

    expect(parsed.llm.auditRecordCount).toBe(1);
    expect(parsed.llm.callers).toEqual(['summary']);
    expect(parsed.llm.trigger).toBe('manual');
    expect(parsed.llm.resolvedSummaryConfig?.preset).toBe('standard');

    // Phase 0 invariant: audit row alone must not back-fill llmSummary.
    expect(parsed.summaries.llmSummary).toBeUndefined();
    expect(parsed.summaries.provenance.llmSummary).toBe('unknown');
  });
});
