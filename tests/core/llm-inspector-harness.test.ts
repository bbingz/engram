import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { AiAuditWriter } from '../../src/core/ai-audit.js';
import { DEFAULT_AI_AUDIT_CONFIG } from '../../src/core/config.js';
import { Database } from '../../src/core/db.js';
import {
  buildResumeInspection,
  buildSessionInspector,
  deriveSessionStatus,
} from '../../src/core/session-inspector.js';

const FIXTURE_ROOT = resolve(
  dirname(fileURLToPath(import.meta.url)),
  '../fixtures/llm-inspector',
);

interface SessionSeed {
  id: string;
  source: string;
  startTime: string;
  endTime?: string | null;
  cwd: string;
  project?: string | null;
  model?: string | null;
  messageCount: number;
  userMessageCount: number;
  assistantMessageCount: number;
  toolMessageCount: number;
  systemMessageCount: number;
  summary?: string | null;
  summaryMessageCount?: number | null;
  filePath: string;
  sizeBytes: number;
  tier?: string | null;
  agentRole?: string | null;
  parentSessionId?: string | null;
  suggestedParentId?: string | null;
  linkSource?: string | null;
  generatedTitle?: string | null;
  indexedAt?: string;
  customName?: string | null;
}

interface CostSeed {
  sessionId: string;
  model: string;
  inputTokens: number;
  outputTokens: number;
  cacheReadTokens: number;
  cacheCreationTokens: number;
  costUsd: number;
  computedAt: string;
}

interface AuditSeed {
  ts?: string;
  caller: 'summary' | 'title' | 'embedding' | 'semantic_index' | 'memory';
  operation: string;
  provider: string;
  model: string;
  promptTokens?: number;
  completionTokens?: number;
  totalTokens?: number;
  durationMs: number;
  sessionId: string;
  meta?: Record<string, unknown>;
  error?: string;
}

interface FixtureFile {
  scenarios: Record<
    string,
    {
      sessions: SessionSeed[];
      costs?: CostSeed[];
      audit?: AuditSeed[];
      target: string;
    }
  >;
}

function insertSessionRow(db: Database, seed: SessionSeed): void {
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
      id: seed.id,
      source: seed.source,
      startTime: seed.startTime,
      endTime: seed.endTime ?? null,
      cwd: seed.cwd,
      project: seed.project ?? null,
      model: seed.model ?? null,
      messageCount: seed.messageCount,
      userMessageCount: seed.userMessageCount,
      assistantMessageCount: seed.assistantMessageCount,
      toolMessageCount: seed.toolMessageCount,
      systemMessageCount: seed.systemMessageCount,
      summary: seed.summary ?? null,
      summaryMessageCount: seed.summaryMessageCount ?? null,
      filePath: seed.filePath,
      sizeBytes: seed.sizeBytes,
      tier: seed.tier ?? null,
      agentRole: seed.agentRole ?? null,
      parentSessionId: seed.parentSessionId ?? null,
      suggestedParentId: seed.suggestedParentId ?? null,
      linkSource: seed.linkSource ?? null,
      generatedTitle: seed.generatedTitle ?? null,
      indexedAt: seed.indexedAt ?? '2026-05-07T08:31:00.000Z',
    });

  if (seed.customName) {
    db.getRawDb()
      .prepare(
        `INSERT INTO session_local_state (session_id, custom_name) VALUES (?, ?)`,
      )
      .run(seed.id, seed.customName);
  }
}

function insertCostRow(db: Database, cost: CostSeed): void {
  db.getRawDb()
    .prepare(`
      INSERT INTO session_costs (
        session_id, model, input_tokens, output_tokens,
        cache_read_tokens, cache_creation_tokens, cost_usd, computed_at
      )
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    `)
    .run(
      cost.sessionId,
      cost.model,
      cost.inputTokens,
      cost.outputTokens,
      cost.cacheReadTokens,
      cost.cacheCreationTokens,
      cost.costUsd,
      cost.computedAt,
    );
}

function insertAuditRowFixed(db: Database, seed: AuditSeed): void {
  db.getRawDb()
    .prepare(`
      INSERT INTO ai_audit_log (
        ts, trace_id, caller, operation, request_source, method, url,
        status_code, duration_ms, model, provider,
        prompt_tokens, completion_tokens, total_tokens,
        request_body, response_body, error, session_id, meta
      ) VALUES (
        @ts, NULL, @caller, @operation, NULL, NULL, NULL, NULL,
        @durationMs, @model, @provider,
        @promptTokens, @completionTokens, @totalTokens,
        NULL, NULL, @error, @sessionId, @meta
      )
    `)
    .run({
      ts: seed.ts ?? '2026-05-07T08:31:00.000',
      caller: seed.caller,
      operation: seed.operation,
      durationMs: seed.durationMs,
      model: seed.model,
      provider: seed.provider,
      promptTokens: seed.promptTokens ?? null,
      completionTokens: seed.completionTokens ?? null,
      totalTokens: seed.totalTokens ?? null,
      error: seed.error ?? null,
      sessionId: seed.sessionId,
      meta: seed.meta ? JSON.stringify(seed.meta) : null,
    });
}

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

  function insertSession(overrides: Partial<SessionSeed> = {}) {
    const base: SessionSeed = {
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
    };
    insertSessionRow(db, { ...base, ...overrides });
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
      generatedTitle: null,
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
      generatedTitle: null,
    });

    insertCostRow(db, {
      sessionId: 'sess-parent',
      model: 'gpt-5.4',
      inputTokens: 100,
      outputTokens: 40,
      cacheReadTokens: 10,
      cacheCreationTokens: 5,
      costUsd: 0.0123,
      computedAt: '2026-05-07T08:31:00.000Z',
    });
    insertCostRow(db, {
      sessionId: 'child-1',
      model: 'gpt-5.4',
      inputTokens: 50,
      outputTokens: 25,
      cacheReadTokens: 0,
      cacheCreationTokens: 0,
      costUsd: 0.0042,
      computedAt: '2026-05-07T08:31:00.000Z',
    });

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
    expect(result?.summaries.storedSummary).toBe(
      'Implemented session inspector contract',
    );
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

  it('keeps parent cost separate from child rollup', () => {
    insertSession({ id: 'parent-cost' });
    insertSession({
      id: 'child-cost-a',
      source: 'codex',
      parentSessionId: 'parent-cost',
      linkSource: 'path',
      filePath: '/tmp/child-cost-a.jsonl',
      tier: 'skip',
      agentRole: 'dispatched',
      summary: null,
      summaryMessageCount: null,
      generatedTitle: null,
    });
    insertCostRow(db, {
      sessionId: 'parent-cost',
      model: 'gpt-5.4',
      inputTokens: 1000,
      outputTokens: 500,
      cacheReadTokens: 0,
      cacheCreationTokens: 0,
      costUsd: 0.99,
      computedAt: '2026-05-07T08:31:00.000Z',
    });
    insertCostRow(db, {
      sessionId: 'child-cost-a',
      model: 'gpt-5.4',
      inputTokens: 100,
      outputTokens: 50,
      cacheReadTokens: 0,
      cacheCreationTokens: 0,
      costUsd: 0.1,
      computedAt: '2026-05-07T08:31:00.000Z',
    });

    const result = buildSessionInspector(db, 'parent-cost');
    expect(result?.cost.estimatedCostUsd).toBeCloseTo(0.99);
    expect(result?.agentGraph.childRollup?.estimatedCostUsd).toBeCloseTo(0.1);
  });

  it('does not populate llmSummary when only a summary audit row exists', () => {
    insertSession({ id: 'audit-only' });
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
      sessionId: 'audit-only',
      meta: { trigger: 'auto' },
    });

    const result = buildSessionInspector(db, 'audit-only');
    expect(result?.summaries.llmSummary).toBeUndefined();
    expect(result?.summaries.provenance.llmSummary).toBe('unknown');
    expect(result?.llm.auditRecordCount).toBe(1);
    expect(result?.llm.trigger).toBe('auto');
  });

  it('normalizes embedding-like callers to embedding', () => {
    insertSession({ id: 'embed-calls' });
    const audit = new AiAuditWriter(db.getRawDb(), {
      ...DEFAULT_AI_AUDIT_CONFIG,
      enabled: true,
      logBodies: false,
    });
    audit.record({
      caller: 'semantic_index',
      operation: 'embed',
      provider: 'ollama',
      model: 'nomic-embed-text',
      durationMs: 8,
      sessionId: 'embed-calls',
    });
    audit.record({
      caller: 'memory',
      operation: 'embed',
      provider: 'ollama',
      model: 'nomic-embed-text',
      durationMs: 9,
      sessionId: 'embed-calls',
    });
    audit.record({
      caller: 'title',
      operation: 'title',
      provider: 'ollama',
      model: 'qwen2.5:7b',
      durationMs: 11,
      sessionId: 'embed-calls',
    });

    const result = buildSessionInspector(db, 'embed-calls');
    expect([...(result?.llm.callers ?? [])].sort()).toEqual([
      'embedding',
      'title',
    ]);
  });

  it('derives status with has_end_time when end_time is set', () => {
    const status = deriveSessionStatus({
      endTime: '2026-05-07T08:30:00.000Z',
      messageCount: 12,
    });
    expect(status.label).toBe('done');
    expect(status.basisTags).toContain('has_end_time');
    expect(status.confidence).toBe('high');
  });

  it('derives status no_messages with low confidence when message count is 0', () => {
    const status = deriveSessionStatus({
      endTime: undefined,
      messageCount: 0,
    });
    expect(status.basisTags).toContain('no_messages');
    expect(status.confidence).toBe('low');
  });

  it('builds resume inspection for codex with resolved command', () => {
    const resume = buildResumeInspection('codex', 'session-xyz', '/some/dir', {
      resolveCommand: (cmd) => `/mock/bin/${cmd}`,
    });
    expect(resume.capability).toBe('supported');
    expect(resume.tool).toBe('codex');
    expect(resume.command).toBe('/mock/bin/codex');
    expect(resume.args).toEqual(['resume', 'session-xyz']);
    expect(resume.cwd).toBe('/some/dir');
    expect(resume.evidence).toBe('local_help');
  });

  it('returns DTO without command/args when resumeResolver is omitted', () => {
    insertSession({ id: 'no-resolver' });
    const result = buildSessionInspector(db, 'no-resolver');
    expect(result).not.toBeNull();
    expect(result?.resume.capability).toBe('unsupported');
    expect(result?.resume.tool).toBe('codex');
    expect(result?.resume.cwd).toBe('/Users/test/work/engram');
    expect(result?.resume.command).toBeUndefined();
    expect(result?.resume.args).toBeUndefined();
    expect(result?.resume.evidence).toBe('fallback');
    expect(result?.resume.warning).toBeTruthy();
  });

  it('builds resume inspection fallback for unknown source', () => {
    const resume = buildResumeInspection('unknown-tool', 'sid', '/path', {
      resolveCommand: () => null,
    });
    expect(resume.capability).toBe('fallback');
    expect(resume.evidence).toBe('fallback');
  });

  describe('fixture-driven scenarios', () => {
    const fixtures: FixtureFile = JSON.parse(
      readFileSync(join(FIXTURE_ROOT, 'session.json'), 'utf-8'),
    );

    function runScenario(name: string, expectedFile: string) {
      const scenario = fixtures.scenarios[name];
      expect(scenario, `scenario ${name} missing`).toBeTruthy();
      for (const seed of scenario.sessions) insertSessionRow(db, seed);
      if (scenario.costs) {
        for (const cost of scenario.costs) insertCostRow(db, cost);
      }
      if (scenario.audit?.length) {
        for (const a of scenario.audit) insertAuditRowFixed(db, a);
      }
      const expected = JSON.parse(
        readFileSync(
          join(FIXTURE_ROOT, 'expected-inspector', expectedFile),
          'utf-8',
        ),
      );
      const actual = buildSessionInspector(db, scenario.target, {
        now: new Date('2026-05-07T09:00:00.000Z'),
        resumeResolver: (cmd) => `/usr/local/bin/${cmd}`,
      });
      expect(actual).toEqual(expected);
    }

    it('matches the full-session golden DTO', () => {
      runScenario('full', 'full-session.json');
    });

    it('matches the missing-facts-session golden DTO', () => {
      runScenario('missingFacts', 'missing-facts-session.json');
    });

    it('matches the child-rollup-session golden DTO', () => {
      runScenario('childRollup', 'child-rollup-session.json');
    });
  });
});
