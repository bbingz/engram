// tests/core/db/parent-link-repo.test.ts

import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import type { SessionInfo } from '../../../src/adapters/types.js';
import {
  backfillCodexOriginator,
  backfillParentLinks,
  backfillSuggestedParents,
  downgradeSubagentTiers,
} from '../../../src/core/db/maintenance.js';
import {
  childCount,
  childSessions,
  clearParentSession,
  clearSuggestedParent,
  confirmSuggestion,
  setParentSession,
  setSuggestedParent,
  suggestedChildCount,
  suggestedChildSessions,
  validateParentLink,
} from '../../../src/core/db/parent-link-repo.js';
import { Database } from '../../../src/core/db.js';

describe('parent-link-repo', () => {
  let db: Database;
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), 'parent-link-test-'));
    db = new Database(join(tmpDir, 'test.sqlite'));
  });

  afterEach(() => {
    db.close();
    rmSync(tmpDir, { recursive: true });
  });

  const makeSession = (overrides: Partial<SessionInfo> = {}): SessionInfo => ({
    id: 'sess-1',
    source: 'claude-code',
    startTime: '2026-01-01T10:00:00.000Z',
    endTime: '2026-01-01T11:00:00.000Z',
    cwd: '/Users/test/project',
    project: 'my-project',
    model: 'claude-sonnet-4-20250514',
    messageCount: 20,
    userMessageCount: 10,
    assistantMessageCount: 8,
    toolMessageCount: 2,
    systemMessageCount: 0,
    summary: 'Fix a bug',
    filePath: '/Users/test/.claude/sessions/sess-1.jsonl',
    sizeBytes: 50000,
    ...overrides,
  });

  // ── validateParentLink ─────────────────────────────────────────

  describe('validateParentLink', () => {
    it('rejects self-link', () => {
      db.upsertSession(makeSession({ id: 'a' }));
      expect(validateParentLink(db.getRawDb(), 'a', 'a')).toBe('self-link');
    });

    it('rejects non-existent parent', () => {
      db.upsertSession(makeSession({ id: 'a' }));
      expect(validateParentLink(db.getRawDb(), 'a', 'no-such')).toBe(
        'parent-not-found',
      );
    });

    it('rejects depth > 1 (parent already has a parent)', () => {
      db.upsertSession(
        makeSession({
          id: 'grandparent',
          filePath: '/f/gp',
          startTime: '2026-01-01T08:00:00Z',
        }),
      );
      db.upsertSession(
        makeSession({
          id: 'parent',
          filePath: '/f/p',
          startTime: '2026-01-01T09:00:00Z',
        }),
      );
      db.upsertSession(
        makeSession({
          id: 'child',
          filePath: '/f/c',
          startTime: '2026-01-01T10:00:00Z',
        }),
      );

      // Set parent → grandparent first
      setParentSession(db.getRawDb(), 'parent', 'grandparent', 'manual');

      // Now child → parent should fail (depth exceeded)
      expect(validateParentLink(db.getRawDb(), 'child', 'parent')).toBe(
        'depth-exceeded',
      );
    });

    it('returns ok for a valid link', () => {
      db.upsertSession(
        makeSession({
          id: 'parent',
          filePath: '/f/p',
          startTime: '2026-01-01T09:00:00Z',
        }),
      );
      db.upsertSession(
        makeSession({
          id: 'child',
          filePath: '/f/c',
          startTime: '2026-01-01T10:00:00Z',
        }),
      );
      expect(validateParentLink(db.getRawDb(), 'child', 'parent')).toBe('ok');
    });
  });

  // ── setParentSession ───────────────────────────────────────────

  describe('setParentSession', () => {
    it('sets parent_session_id and link_source', () => {
      db.upsertSession(
        makeSession({
          id: 'parent',
          filePath: '/f/p',
          startTime: '2026-01-01T09:00:00Z',
        }),
      );
      db.upsertSession(
        makeSession({
          id: 'child',
          filePath: '/f/c',
          startTime: '2026-01-01T10:00:00Z',
        }),
      );
      setParentSession(db.getRawDb(), 'child', 'parent', 'path');

      const raw = db.getRawDb();
      const row = raw
        .prepare(
          'SELECT parent_session_id, link_source FROM sessions WHERE id = ?',
        )
        .get('child') as Record<string, unknown>;
      expect(row.parent_session_id).toBe('parent');
      expect(row.link_source).toBe('path');
    });

    it('clears suggested_parent_id when setting confirmed parent', () => {
      db.upsertSession(
        makeSession({
          id: 'parent',
          filePath: '/f/p',
          startTime: '2026-01-01T09:00:00Z',
        }),
      );
      db.upsertSession(
        makeSession({
          id: 'child',
          filePath: '/f/c',
          startTime: '2026-01-01T10:00:00Z',
        }),
      );

      // First set a suggestion
      setSuggestedParent(db.getRawDb(), 'child', 'parent');

      // Then confirm via setParentSession
      setParentSession(db.getRawDb(), 'child', 'parent', 'manual');

      const raw = db.getRawDb();
      const row = raw
        .prepare('SELECT suggested_parent_id FROM sessions WHERE id = ?')
        .get('child') as Record<string, unknown>;
      expect(row.suggested_parent_id).toBeNull();
    });

    it('does not modify tier when linking', () => {
      db.upsertSession(
        makeSession({
          id: 'parent',
          filePath: '/f/p',
          startTime: '2026-01-01T09:00:00Z',
        }),
      );
      db.upsertSession(
        makeSession({
          id: 'child',
          filePath: '/f/c',
          startTime: '2026-01-01T10:00:00Z',
          tier: 'skip',
        }),
      );
      db.getRawDb()
        .prepare("UPDATE sessions SET tier = 'skip' WHERE id = 'child'")
        .run();

      setParentSession(db.getRawDb(), 'child', 'parent', 'path');

      const row = db
        .getRawDb()
        .prepare('SELECT tier FROM sessions WHERE id = ?')
        .get('child') as Record<string, unknown>;
      expect(row.tier).toBe('skip');
    });
  });

  // ── clearParentSession ─────────────────────────────────────────

  describe('clearParentSession', () => {
    it('clears parent and sets link_source to manual', () => {
      db.upsertSession(
        makeSession({
          id: 'parent',
          filePath: '/f/p',
          startTime: '2026-01-01T09:00:00Z',
        }),
      );
      db.upsertSession(
        makeSession({
          id: 'child',
          filePath: '/f/c',
          startTime: '2026-01-01T10:00:00Z',
        }),
      );
      setParentSession(db.getRawDb(), 'child', 'parent', 'path');
      clearParentSession(db.getRawDb(), 'child');

      const raw = db.getRawDb();
      const row = raw
        .prepare(
          'SELECT parent_session_id, link_source, tier FROM sessions WHERE id = ?',
        )
        .get('child') as Record<string, unknown>;
      expect(row.parent_session_id).toBeNull();
      expect(row.link_source).toBe('manual');
      expect(row.tier).toBeNull();
    });
  });

  // ── childSessions ──────────────────────────────────────────────

  describe('childSessions', () => {
    it('returns children sorted by start_time ASC, paginated', () => {
      db.upsertSession(
        makeSession({
          id: 'parent',
          filePath: '/f/p',
          startTime: '2026-01-01T08:00:00Z',
        }),
      );
      db.upsertSession(
        makeSession({
          id: 'c1',
          filePath: '/f/c1',
          startTime: '2026-01-01T10:00:00Z',
        }),
      );
      db.upsertSession(
        makeSession({
          id: 'c2',
          filePath: '/f/c2',
          startTime: '2026-01-01T09:00:00Z',
        }),
      );
      db.upsertSession(
        makeSession({
          id: 'c3',
          filePath: '/f/c3',
          startTime: '2026-01-01T11:00:00Z',
        }),
      );

      setParentSession(db.getRawDb(), 'c1', 'parent', 'path');
      setParentSession(db.getRawDb(), 'c2', 'parent', 'path');
      setParentSession(db.getRawDb(), 'c3', 'parent', 'path');

      // All children
      const all = childSessions(db.getRawDb(), 'parent', 10, 0);
      expect(all).toHaveLength(3);
      expect(all[0].id).toBe('c2'); // earliest
      expect(all[2].id).toBe('c3'); // latest

      // Paginated
      const page1 = childSessions(db.getRawDb(), 'parent', 2, 0);
      expect(page1).toHaveLength(2);
      expect(page1[0].id).toBe('c2');
      expect(page1[1].id).toBe('c1');

      const page2 = childSessions(db.getRawDb(), 'parent', 2, 2);
      expect(page2).toHaveLength(1);
      expect(page2[0].id).toBe('c3');
    });

    it('returns SessionInfo with parentSessionId populated', () => {
      db.upsertSession(
        makeSession({
          id: 'parent',
          filePath: '/f/p',
          startTime: '2026-01-01T08:00:00Z',
        }),
      );
      db.upsertSession(
        makeSession({
          id: 'child',
          filePath: '/f/c',
          startTime: '2026-01-01T10:00:00Z',
        }),
      );
      setParentSession(db.getRawDb(), 'child', 'parent', 'path');

      const children = childSessions(db.getRawDb(), 'parent', 10, 0);
      expect(children).toHaveLength(1);
      expect(children[0].parentSessionId).toBe('parent');
    });
  });

  // ── childCount ─────────────────────────────────────────────────

  describe('childCount', () => {
    it('returns counts for multiple parents in batch', () => {
      db.upsertSession(
        makeSession({
          id: 'p1',
          filePath: '/f/p1',
          startTime: '2026-01-01T08:00:00Z',
        }),
      );
      db.upsertSession(
        makeSession({
          id: 'p2',
          filePath: '/f/p2',
          startTime: '2026-01-01T08:00:00Z',
        }),
      );
      db.upsertSession(
        makeSession({
          id: 'c1',
          filePath: '/f/c1',
          startTime: '2026-01-01T10:00:00Z',
        }),
      );
      db.upsertSession(
        makeSession({
          id: 'c2',
          filePath: '/f/c2',
          startTime: '2026-01-01T10:00:00Z',
        }),
      );
      db.upsertSession(
        makeSession({
          id: 'c3',
          filePath: '/f/c3',
          startTime: '2026-01-01T10:00:00Z',
        }),
      );

      setParentSession(db.getRawDb(), 'c1', 'p1', 'path');
      setParentSession(db.getRawDb(), 'c2', 'p1', 'path');
      setParentSession(db.getRawDb(), 'c3', 'p2', 'path');

      const counts = childCount(db.getRawDb(), ['p1', 'p2']);
      expect(counts.get('p1')).toBe(2);
      expect(counts.get('p2')).toBe(1);
    });

    it('returns 0 for parents with no children', () => {
      db.upsertSession(
        makeSession({
          id: 'lonely',
          filePath: '/f/l',
          startTime: '2026-01-01T08:00:00Z',
        }),
      );
      const counts = childCount(db.getRawDb(), ['lonely']);
      expect(counts.get('lonely')).toBe(0);
    });

    it('handles empty input', () => {
      const counts = childCount(db.getRawDb(), []);
      expect(counts.size).toBe(0);
    });
  });

  // ── setSuggestedParent ─────────────────────────────────────────

  describe('setSuggestedParent', () => {
    it('sets suggested_parent_id and link_checked_at', () => {
      db.upsertSession(
        makeSession({
          id: 'parent',
          filePath: '/f/p',
          startTime: '2026-01-01T09:00:00Z',
        }),
      );
      db.upsertSession(
        makeSession({
          id: 'child',
          filePath: '/f/c',
          startTime: '2026-01-01T10:00:00Z',
        }),
      );
      setSuggestedParent(db.getRawDb(), 'child', 'parent');

      const raw = db.getRawDb();
      const row = raw
        .prepare(
          'SELECT suggested_parent_id, link_checked_at FROM sessions WHERE id = ?',
        )
        .get('child') as Record<string, unknown>;
      expect(row.suggested_parent_id).toBe('parent');
      expect(row.link_checked_at).toBeTruthy();
    });
  });

  // ── clearSuggestedParent ───────────────────────────────────────

  describe('clearSuggestedParent', () => {
    it('clears only if expectedParentId matches', () => {
      db.upsertSession(
        makeSession({
          id: 'parent',
          filePath: '/f/p',
          startTime: '2026-01-01T09:00:00Z',
        }),
      );
      db.upsertSession(
        makeSession({
          id: 'child',
          filePath: '/f/c',
          startTime: '2026-01-01T10:00:00Z',
        }),
      );
      setSuggestedParent(db.getRawDb(), 'child', 'parent');

      // Wrong expected — no-op
      const cleared1 = clearSuggestedParent(db.getRawDb(), 'child', 'wrong-id');
      expect(cleared1).toBe(false);

      const raw = db.getRawDb();
      const row1 = raw
        .prepare('SELECT suggested_parent_id FROM sessions WHERE id = ?')
        .get('child') as Record<string, unknown>;
      expect(row1.suggested_parent_id).toBe('parent');

      // Correct expected — clears
      const cleared2 = clearSuggestedParent(db.getRawDb(), 'child', 'parent');
      expect(cleared2).toBe(true);

      const row2 = raw
        .prepare('SELECT suggested_parent_id FROM sessions WHERE id = ?')
        .get('child') as Record<string, unknown>;
      expect(row2.suggested_parent_id).toBeNull();
    });
  });

  // ── suggestedChildSessions ─────────────────────────────────────

  describe('suggestedChildSessions', () => {
    it('returns sessions with matching suggested_parent_id', () => {
      db.upsertSession(
        makeSession({
          id: 'parent',
          filePath: '/f/p',
          startTime: '2026-01-01T08:00:00Z',
        }),
      );
      db.upsertSession(
        makeSession({
          id: 'c1',
          filePath: '/f/c1',
          startTime: '2026-01-01T10:00:00Z',
        }),
      );
      db.upsertSession(
        makeSession({
          id: 'c2',
          filePath: '/f/c2',
          startTime: '2026-01-01T09:00:00Z',
        }),
      );

      setSuggestedParent(db.getRawDb(), 'c1', 'parent');
      setSuggestedParent(db.getRawDb(), 'c2', 'parent');

      const results = suggestedChildSessions(db.getRawDb(), 'parent');
      expect(results).toHaveLength(2);
      // Sorted by start_time ASC
      expect(results[0].id).toBe('c2');
      expect(results[1].id).toBe('c1');
      expect(results[0].suggestedParentId).toBe('parent');
    });
  });

  // ── suggestedChildCount ────────────────────────────────────────

  describe('suggestedChildCount', () => {
    it('returns counts for multiple parents', () => {
      db.upsertSession(
        makeSession({
          id: 'p1',
          filePath: '/f/p1',
          startTime: '2026-01-01T08:00:00Z',
        }),
      );
      db.upsertSession(
        makeSession({
          id: 'p2',
          filePath: '/f/p2',
          startTime: '2026-01-01T08:00:00Z',
        }),
      );
      db.upsertSession(
        makeSession({
          id: 'c1',
          filePath: '/f/c1',
          startTime: '2026-01-01T10:00:00Z',
        }),
      );
      db.upsertSession(
        makeSession({
          id: 'c2',
          filePath: '/f/c2',
          startTime: '2026-01-01T10:00:00Z',
        }),
      );

      setSuggestedParent(db.getRawDb(), 'c1', 'p1');
      setSuggestedParent(db.getRawDb(), 'c2', 'p1');

      const counts = suggestedChildCount(db.getRawDb(), ['p1', 'p2']);
      expect(counts.get('p1')).toBe(2);
      expect(counts.get('p2')).toBe(0);
    });
  });

  // ── confirmSuggestion ──────────────────────────────────────────

  describe('confirmSuggestion', () => {
    it('promotes suggested parent to confirmed', () => {
      db.upsertSession(
        makeSession({
          id: 'parent',
          filePath: '/f/p',
          startTime: '2026-01-01T09:00:00Z',
        }),
      );
      db.upsertSession(
        makeSession({
          id: 'child',
          filePath: '/f/c',
          startTime: '2026-01-01T10:00:00Z',
        }),
      );
      setSuggestedParent(db.getRawDb(), 'child', 'parent');

      const result = confirmSuggestion(db.getRawDb(), 'child');
      expect(result.ok).toBe(true);

      const raw = db.getRawDb();
      const row = raw
        .prepare(
          'SELECT parent_session_id, suggested_parent_id, link_source FROM sessions WHERE id = ?',
        )
        .get('child') as Record<string, unknown>;
      expect(row.parent_session_id).toBe('parent');
      expect(row.suggested_parent_id).toBeNull();
      expect(row.link_source).toBe('manual');
    });

    it('rejects when no suggestion exists', () => {
      db.upsertSession(
        makeSession({
          id: 'child',
          filePath: '/f/c',
          startTime: '2026-01-01T10:00:00Z',
        }),
      );
      const result = confirmSuggestion(db.getRawDb(), 'child');
      expect(result.ok).toBe(false);
      expect(result.error).toContain('no suggestion');
    });

    it('rejects when suggested parent has been deleted (trigger clears suggestion)', () => {
      db.upsertSession(
        makeSession({
          id: 'parent',
          filePath: '/f/p',
          startTime: '2026-01-01T09:00:00Z',
        }),
      );
      db.upsertSession(
        makeSession({
          id: 'child',
          filePath: '/f/c',
          startTime: '2026-01-01T10:00:00Z',
        }),
      );
      setSuggestedParent(db.getRawDb(), 'child', 'parent');

      // Delete parent — orphan trigger clears suggested_parent_id
      db.deleteSession('parent');

      const result = confirmSuggestion(db.getRawDb(), 'child');
      expect(result.ok).toBe(false);
      // Trigger already cleared the suggestion, so error is 'no suggestion'
      expect(result.error).toContain('no suggestion');
    });

    it('keeps tier unchanged on confirm (no longer upgrades skip to lite)', () => {
      db.upsertSession(
        makeSession({
          id: 'parent',
          filePath: '/f/p',
          startTime: '2026-01-01T09:00:00Z',
        }),
      );
      db.upsertSession(
        makeSession({
          id: 'child',
          filePath: '/f/c',
          startTime: '2026-01-01T10:00:00Z',
        }),
      );
      db.getRawDb()
        .prepare("UPDATE sessions SET tier = 'skip' WHERE id = 'child'")
        .run();

      setSuggestedParent(db.getRawDb(), 'child', 'parent');
      const result = confirmSuggestion(db.getRawDb(), 'child');
      expect(result.ok).toBe(true);

      const row = db
        .getRawDb()
        .prepare('SELECT tier FROM sessions WHERE id = ?')
        .get('child') as Record<string, unknown>;
      expect(row.tier).toBe('skip');
    });
  });

  // ── orphan trigger verification ────────────────────────────────

  describe('orphan trigger', () => {
    it('clears parent_session_id when parent is deleted', () => {
      db.upsertSession(
        makeSession({
          id: 'parent',
          filePath: '/f/p',
          startTime: '2026-01-01T09:00:00Z',
        }),
      );
      db.upsertSession(
        makeSession({
          id: 'child',
          filePath: '/f/c',
          startTime: '2026-01-01T10:00:00Z',
        }),
      );
      setParentSession(db.getRawDb(), 'child', 'parent', 'path');

      // Verify link exists
      const before = db
        .getRawDb()
        .prepare('SELECT parent_session_id FROM sessions WHERE id = ?')
        .get('child') as Record<string, unknown>;
      expect(before.parent_session_id).toBe('parent');

      // Delete parent
      db.deleteSession('parent');

      // Trigger should have cleared it
      const after = db
        .getRawDb()
        .prepare(
          'SELECT parent_session_id, link_source, tier FROM sessions WHERE id = ?',
        )
        .get('child') as Record<string, unknown>;
      expect(after.parent_session_id).toBeNull();
      expect(after.link_source).toBeNull();
      expect(after.tier).toBeNull();
    });

    it('clears suggested_parent_id when suggested parent is deleted', () => {
      db.upsertSession(
        makeSession({
          id: 'parent',
          filePath: '/f/p',
          startTime: '2026-01-01T09:00:00Z',
        }),
      );
      db.upsertSession(
        makeSession({
          id: 'child',
          filePath: '/f/c',
          startTime: '2026-01-01T10:00:00Z',
        }),
      );
      setSuggestedParent(db.getRawDb(), 'child', 'parent');

      db.deleteSession('parent');

      const row = db
        .getRawDb()
        .prepare('SELECT suggested_parent_id FROM sessions WHERE id = ?')
        .get('child') as Record<string, unknown>;
      expect(row.suggested_parent_id).toBeNull();
    });
  });

  // ── backfillParentLinks ─────────────────────────────────────────

  describe('backfillParentLinks', () => {
    it('links subagent sessions to parent via agent_role', () => {
      db.upsertSession(
        makeSession({
          id: 'sess-abc',
          source: 'claude-code',
          startTime: '2026-04-13T10:00:00Z',
          filePath: '/home/.claude/projects/myproj/sess-abc.jsonl',
          sizeBytes: 100,
        }),
      );
      db.raw
        .prepare(
          `
        INSERT INTO sessions (id, source, start_time, cwd, file_path, size_bytes, agent_role, message_count, user_message_count)
        VALUES ('agent-xyz', 'claude-code', '2026-04-13T10:05:00Z', '/test',
                '/home/.claude/projects/myproj/sess-abc/subagents/agent-xyz.jsonl', 50, 'subagent', 5, 2)
      `,
        )
        .run();

      const result = backfillParentLinks(db.raw);
      expect(result.linked).toBe(1);
      const row = db.raw
        .prepare(
          'SELECT parent_session_id, link_source FROM sessions WHERE id = ?',
        )
        .get('agent-xyz') as Record<string, unknown>;
      expect(row.parent_session_id).toBe('sess-abc');
      expect(row.link_source).toBe('path');
    });

    it('skips manually unlinked sessions', () => {
      db.upsertSession(
        makeSession({
          id: 'sess-abc',
          source: 'claude-code',
          startTime: '2026-04-13T10:00:00Z',
          filePath: '/home/.claude/projects/myproj/sess-abc.jsonl',
          sizeBytes: 100,
        }),
      );
      db.raw
        .prepare(
          `
        INSERT INTO sessions (id, source, start_time, cwd, file_path, size_bytes, agent_role, link_source, message_count, user_message_count)
        VALUES ('agent-manual', 'claude-code', '2026-04-13T10:05:00Z', '/test',
                '/home/.claude/projects/myproj/sess-abc/subagents/agent-manual.jsonl', 50, 'subagent', 'manual', 5, 2)
      `,
        )
        .run();
      const result = backfillParentLinks(db.raw);
      expect(result.linked).toBe(0);
    });

    it('keeps subagent tier as skip after linking', () => {
      db.upsertSession(
        makeSession({
          id: 'sess-p',
          source: 'claude-code',
          startTime: '2026-04-13T10:00:00Z',
          filePath: '/home/.claude/projects/myproj/sess-p.jsonl',
          sizeBytes: 100,
        }),
      );
      db.raw
        .prepare(
          `
        INSERT INTO sessions (id, source, start_time, cwd, file_path, size_bytes, agent_role, tier, message_count, user_message_count)
        VALUES ('agent-t', 'claude-code', '2026-04-13T10:05:00Z', '/test',
                '/home/.claude/projects/myproj/sess-p/subagents/agent-t.jsonl', 50, 'subagent', 'skip', 5, 2)
      `,
        )
        .run();
      backfillParentLinks(db.raw);
      const row = db.raw
        .prepare('SELECT tier FROM sessions WHERE id = ?')
        .get('agent-t') as Record<string, unknown>;
      expect(row.tier).toBe('skip');
    });
  });

  // ── downgradeSubagentTiers ───────────────────────────────────────

  describe('downgradeSubagentTiers', () => {
    it('downgrades subagent sessions from lite to skip', () => {
      db.raw
        .prepare(
          `
        INSERT INTO sessions (id, source, start_time, cwd, file_path, size_bytes, agent_role, tier, message_count, user_message_count)
        VALUES ('agent-a', 'claude-code', '2026-04-13T10:05:00Z', '/test',
                '/home/.claude/projects/myproj/sess/subagents/agent-a.jsonl', 50, 'subagent', 'lite', 5, 2)
      `,
        )
        .run();

      const count = downgradeSubagentTiers(db.raw);
      expect(count).toBe(1);

      const row = db.raw
        .prepare('SELECT tier FROM sessions WHERE id = ?')
        .get('agent-a') as Record<string, unknown>;
      expect(row.tier).toBe('skip');
    });

    it('does not touch non-subagent sessions', () => {
      db.upsertSession(
        makeSession({
          id: 'normal-sess',
          source: 'claude-code',
          startTime: '2026-04-13T10:00:00Z',
          filePath: '/home/.claude/projects/myproj/normal.jsonl',
          sizeBytes: 100,
        }),
      );
      db.raw
        .prepare("UPDATE sessions SET tier = 'lite' WHERE id = 'normal-sess'")
        .run();

      const count = downgradeSubagentTiers(db.raw);
      expect(count).toBe(0);

      const row = db.raw
        .prepare('SELECT tier FROM sessions WHERE id = ?')
        .get('normal-sess') as Record<string, unknown>;
      expect(row.tier).toBe('lite');
    });
  });

  // ── backfillSuggestedParents ────────────────────────────────────

  describe('backfillSuggestedParents', () => {
    it('suggests parent for gemini session with dispatch pattern', () => {
      db.upsertSession(
        makeSession({
          id: 'cc-parent',
          source: 'claude-code',
          startTime: '2026-04-13T10:00:00Z',
          endTime: '2026-04-13T12:00:00Z',
          cwd: '/test',
          project: 'myproj',
          filePath: '/test/cc.jsonl',
          sizeBytes: 100,
        }),
      );
      db.upsertSession(
        makeSession({
          id: 'gem-agent',
          source: 'gemini-cli',
          startTime: '2026-04-13T10:05:00Z',
          cwd: '/test',
          project: 'myproj',
          filePath: '/test/gem.json',
          sizeBytes: 50,
          summary: '<task> Review the insight-hardening branch...',
        }),
      );

      const result = backfillSuggestedParents(db.raw);
      expect(result.checked).toBe(1);
      expect(result.suggested).toBeGreaterThanOrEqual(1);

      const row = db.raw
        .prepare(
          'SELECT suggested_parent_id, link_checked_at FROM sessions WHERE id = ?',
        )
        .get('gem-agent') as Record<string, unknown>;
      expect(row.suggested_parent_id).toBe('cc-parent');
      expect(row.link_checked_at).toBeTruthy();
    });

    it('marks link_checked_at even when no parent found', () => {
      db.upsertSession(
        makeSession({
          id: 'gem-orphan',
          source: 'gemini-cli',
          startTime: '2026-04-13T10:05:00Z',
          cwd: '/test',
          project: 'myproj',
          filePath: '/test/gem-orphan.json',
          sizeBytes: 50,
          summary: '<task> Something with no parent...',
        }),
      );

      backfillSuggestedParents(db.raw);

      const row = db.raw
        .prepare('SELECT link_checked_at, tier FROM sessions WHERE id = ?')
        .get('gem-orphan') as Record<string, unknown>;
      expect(row.link_checked_at).toBeTruthy();
      expect(row.tier).toBe('skip');
    });

    it('skips sessions without dispatch pattern summary', () => {
      db.upsertSession(
        makeSession({
          id: 'gem-normal',
          source: 'gemini-cli',
          startTime: '2026-04-13T10:05:00Z',
          cwd: '/test',
          project: 'myproj',
          filePath: '/test/gem-normal.json',
          sizeBytes: 50,
          summary: 'Just a regular conversation about code',
        }),
      );

      const result = backfillSuggestedParents(db.raw);
      expect(result.checked).toBe(1);
      expect(result.suggested).toBe(0);

      const row = db.raw
        .prepare(
          'SELECT suggested_parent_id, link_checked_at FROM sessions WHERE id = ?',
        )
        .get('gem-normal') as Record<string, unknown>;
      expect(row.suggested_parent_id).toBeNull();
      expect(row.link_checked_at).toBeTruthy();
    });

    it('skips sessions that already have link_checked_at', () => {
      db.upsertSession(
        makeSession({
          id: 'gem-checked',
          source: 'gemini-cli',
          startTime: '2026-04-13T10:05:00Z',
          cwd: '/test',
          project: 'myproj',
          filePath: '/test/gem-checked.json',
          sizeBytes: 50,
          summary: '<task> Already checked...',
        }),
      );
      // Manually set link_checked_at
      db.raw
        .prepare(
          "UPDATE sessions SET link_checked_at = datetime('now') WHERE id = ?",
        )
        .run('gem-checked');

      const result = backfillSuggestedParents(db.raw);
      expect(result.checked).toBe(0);
    });

    it('suggests parent for codex sessions too', () => {
      db.upsertSession(
        makeSession({
          id: 'cc-parent2',
          source: 'claude-code',
          startTime: '2026-04-13T10:00:00Z',
          endTime: '2026-04-13T12:00:00Z',
          cwd: '/test',
          project: 'myproj',
          filePath: '/test/cc2.jsonl',
          sizeBytes: 100,
        }),
      );
      db.upsertSession(
        makeSession({
          id: 'codex-agent',
          source: 'codex',
          startTime: '2026-04-13T10:02:00Z',
          cwd: '/test',
          project: 'myproj',
          filePath: '/test/codex.json',
          sizeBytes: 50,
          summary: 'Your task is to fix the login flow...',
        }),
      );

      const result = backfillSuggestedParents(db.raw);
      expect(result.suggested).toBe(1);

      const row = db.raw
        .prepare('SELECT suggested_parent_id FROM sessions WHERE id = ?')
        .get('codex-agent') as Record<string, unknown>;
      expect(row.suggested_parent_id).toBe('cc-parent2');
    });

    it('does not suggest a parent for ordinary user follow-up prompts', () => {
      db.upsertSession(
        makeSession({
          id: 'cc-parent3',
          source: 'claude-code',
          startTime: '2026-04-13T10:00:00Z',
          endTime: '2026-04-13T12:00:00Z',
          cwd: '/test',
          project: 'myproj',
          filePath: '/test/cc3.jsonl',
          sizeBytes: 100,
        }),
      );
      db.upsertSession(
        makeSession({
          id: 'codex-normal-followup',
          source: 'codex',
          startTime: '2026-04-13T10:02:00Z',
          cwd: '/test',
          project: 'myproj',
          filePath: '/test/codex-normal-followup.json',
          sizeBytes: 50,
          summary: 'Say more about vector search tradeoffs',
        }),
      );

      const result = backfillSuggestedParents(db.raw);
      expect(result.checked).toBe(1);
      expect(result.suggested).toBe(0);

      const row = db.raw
        .prepare(
          'SELECT suggested_parent_id, link_checked_at FROM sessions WHERE id = ?',
        )
        .get('codex-normal-followup') as Record<string, unknown>;
      expect(row.suggested_parent_id).toBeNull();
      expect(row.link_checked_at).toBeTruthy();
    });
  });

  describe('backfillCodexOriginator', () => {
    it('marks Claude Code-originated Codex sessions as dispatched and skip-tier', () => {
      const tempFile = join(tmpDir, 'codex-originator.jsonl');
      writeFileSync(
        tempFile,
        `${JSON.stringify({
          type: 'session_meta',
          payload: {
            id: 'codex-originator',
            originator: 'Claude Code',
          },
        })}\n`,
      );

      db.upsertSession(
        makeSession({
          id: 'codex-originator',
          source: 'codex',
          startTime: '2026-04-13T10:02:00Z',
          cwd: '/test',
          project: 'myproj',
          filePath: tempFile,
          sizeBytes: 50,
          summary: 'Regular summary',
          tier: 'normal',
        }),
      );

      const updated = backfillCodexOriginator(db.raw);
      expect(updated).toBe(1);

      const row = db.raw
        .prepare(
          'SELECT agent_role, tier, link_checked_at FROM sessions WHERE id = ?',
        )
        .get('codex-originator') as Record<string, unknown>;
      expect(row.agent_role).toBe('dispatched');
      expect(row.tier).toBe('skip');
      expect(row.link_checked_at).toBeNull();
    });
  });

  // ── rowToSessionInfo includes new fields ───────────────────────

  describe('SessionInfo includes parent fields', () => {
    it('getSession returns parentSessionId and suggestedParentId', () => {
      db.upsertSession(
        makeSession({
          id: 'parent',
          filePath: '/f/p',
          startTime: '2026-01-01T09:00:00Z',
        }),
      );
      db.upsertSession(
        makeSession({
          id: 'child',
          filePath: '/f/c',
          startTime: '2026-01-01T10:00:00Z',
        }),
      );
      setParentSession(db.getRawDb(), 'child', 'parent', 'path');

      const session = db.getSession('child');
      expect(session).not.toBeNull();
      expect(session?.parentSessionId).toBe('parent');
    });

    it('getSession returns suggestedParentId', () => {
      db.upsertSession(
        makeSession({
          id: 'parent',
          filePath: '/f/p',
          startTime: '2026-01-01T09:00:00Z',
        }),
      );
      db.upsertSession(
        makeSession({
          id: 'child',
          filePath: '/f/c',
          startTime: '2026-01-01T10:00:00Z',
        }),
      );
      setSuggestedParent(db.getRawDb(), 'child', 'parent');

      const session = db.getSession('child');
      expect(session).not.toBeNull();
      expect(session?.suggestedParentId).toBe('parent');
    });
  });
});
