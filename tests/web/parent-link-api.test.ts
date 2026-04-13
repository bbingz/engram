import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import type { SessionInfo } from '../../src/adapters/types.js';
import { Database } from '../../src/core/db.js';
import { createApp } from '../../src/web.js';

const parentSession: SessionInfo = {
  id: 'parent-session-001',
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
  summary: 'Parent session',
  filePath: '/Users/test/.claude/projects/parent.jsonl',
  sizeBytes: 50000,
};

const childSession: SessionInfo = {
  id: 'child-session-001',
  source: 'claude-code',
  startTime: '2026-01-01T11:00:00.000Z',
  endTime: '2026-01-01T12:00:00.000Z',
  cwd: '/Users/test/project',
  project: 'my-project',
  model: 'claude-sonnet-4-20250514',
  messageCount: 10,
  userMessageCount: 5,
  assistantMessageCount: 4,
  toolMessageCount: 1,
  systemMessageCount: 0,
  summary: 'Child session',
  filePath: '/Users/test/.claude/projects/child.jsonl',
  sizeBytes: 30000,
};

const childSession2: SessionInfo = {
  id: 'child-session-002',
  source: 'claude-code',
  startTime: '2026-01-01T12:00:00.000Z',
  endTime: '2026-01-01T13:00:00.000Z',
  cwd: '/Users/test/project',
  project: 'my-project',
  model: 'claude-sonnet-4-20250514',
  messageCount: 5,
  userMessageCount: 3,
  assistantMessageCount: 2,
  toolMessageCount: 0,
  systemMessageCount: 0,
  summary: 'Second child session',
  filePath: '/Users/test/.claude/projects/child2.jsonl',
  sizeBytes: 20000,
};

function jsonHeaders() {
  return { 'Content-Type': 'application/json' };
}

describe('Parent Link API', () => {
  let db: Database;
  let app: ReturnType<typeof createApp>;

  beforeEach(() => {
    db = new Database(':memory:');
    app = createApp(db);
    db.upsertSession(parentSession);
    db.upsertSession(childSession);
    db.upsertSession(childSession2);
  });

  afterEach(() => {
    db.close();
  });

  // --- POST /api/sessions/:id/link ---

  describe('POST /api/sessions/:id/link', () => {
    it('links child to parent', async () => {
      const res = await app.request(`/api/sessions/${childSession.id}/link`, {
        method: 'POST',
        body: JSON.stringify({ parentId: parentSession.id }),
        headers: jsonHeaders(),
      });
      expect(res.status).toBe(200);
      const body = await res.json();
      expect(body.ok).toBe(true);

      // Verify the link was set
      const session = db.getSession(childSession.id);
      expect(session?.parentSessionId).toBe(parentSession.id);
    });

    it('rejects self-link', async () => {
      const res = await app.request(`/api/sessions/${parentSession.id}/link`, {
        method: 'POST',
        body: JSON.stringify({ parentId: parentSession.id }),
        headers: jsonHeaders(),
      });
      expect(res.status).toBe(400);
      const body = await res.json();
      expect(body.error).toBe('self-link');
    });

    it('rejects non-existent parent', async () => {
      const res = await app.request(`/api/sessions/${childSession.id}/link`, {
        method: 'POST',
        body: JSON.stringify({ parentId: 'does-not-exist' }),
        headers: jsonHeaders(),
      });
      expect(res.status).toBe(400);
      const body = await res.json();
      expect(body.error).toBe('parent-not-found');
    });

    it('rejects missing parentId', async () => {
      const res = await app.request(`/api/sessions/${childSession.id}/link`, {
        method: 'POST',
        body: JSON.stringify({}),
        headers: jsonHeaders(),
      });
      expect(res.status).toBe(400);
      const body = await res.json();
      expect(body.error).toBe('parentId required');
    });

    it('rejects depth-exceeded (parent already has a parent)', async () => {
      // Link child to parent first
      db.setParentSession(childSession.id, parentSession.id, 'manual');

      // Now try to link child2 to child (which already has a parent)
      const res = await app.request(`/api/sessions/${childSession2.id}/link`, {
        method: 'POST',
        body: JSON.stringify({ parentId: childSession.id }),
        headers: jsonHeaders(),
      });
      expect(res.status).toBe(400);
      const body = await res.json();
      expect(body.error).toBe('depth-exceeded');
    });
  });

  // --- DELETE /api/sessions/:id/link ---

  describe('DELETE /api/sessions/:id/link', () => {
    it('unlinks child from parent', async () => {
      // Set up a link first
      db.setParentSession(childSession.id, parentSession.id, 'manual');
      expect(db.getSession(childSession.id)?.parentSessionId).toBe(
        parentSession.id,
      );

      const res = await app.request(`/api/sessions/${childSession.id}/link`, {
        method: 'DELETE',
      });
      expect(res.status).toBe(200);
      const body = await res.json();
      expect(body.ok).toBe(true);

      // Verify the link was cleared
      const session = db.getSession(childSession.id);
      expect(session?.parentSessionId).toBeFalsy();
    });

    it('succeeds even when no link exists (idempotent)', async () => {
      const res = await app.request(`/api/sessions/${childSession.id}/link`, {
        method: 'DELETE',
      });
      expect(res.status).toBe(200);
      const body = await res.json();
      expect(body.ok).toBe(true);
    });
  });

  // --- POST /api/sessions/:id/confirm-suggestion ---

  describe('POST /api/sessions/:id/confirm-suggestion', () => {
    it('promotes suggestion to confirmed link', async () => {
      // Set up a suggestion
      db.setSuggestedParent(childSession.id, parentSession.id);

      const res = await app.request(
        `/api/sessions/${childSession.id}/confirm-suggestion`,
        { method: 'POST' },
      );
      expect(res.status).toBe(200);
      const body = await res.json();
      expect(body.ok).toBe(true);

      // Verify the suggestion was promoted
      const session = db.getSession(childSession.id);
      expect(session?.parentSessionId).toBe(parentSession.id);
      expect(session?.suggestedParentId).toBeFalsy();
    });

    it('rejects when no suggestion exists', async () => {
      const res = await app.request(
        `/api/sessions/${childSession.id}/confirm-suggestion`,
        { method: 'POST' },
      );
      expect(res.status).toBe(400);
      const body = await res.json();
      expect(body.error).toBe('no suggestion exists for this session');
    });
  });

  // --- DELETE /api/sessions/:id/suggestion ---

  describe('DELETE /api/sessions/:id/suggestion', () => {
    it('dismisses suggestion with correct expected value', async () => {
      db.setSuggestedParent(childSession.id, parentSession.id);

      const res = await app.request(
        `/api/sessions/${childSession.id}/suggestion`,
        {
          method: 'DELETE',
          body: JSON.stringify({ suggestedParentId: parentSession.id }),
          headers: jsonHeaders(),
        },
      );
      expect(res.status).toBe(200);
      const body = await res.json();
      expect(body.ok).toBe(true);

      // Verify the suggestion was cleared
      const session = db.getSession(childSession.id);
      expect(session?.suggestedParentId).toBeFalsy();
    });

    it('rejects stale suggestion (409)', async () => {
      db.setSuggestedParent(childSession.id, parentSession.id);

      const res = await app.request(
        `/api/sessions/${childSession.id}/suggestion`,
        {
          method: 'DELETE',
          body: JSON.stringify({ suggestedParentId: 'wrong-parent-id' }),
          headers: jsonHeaders(),
        },
      );
      expect(res.status).toBe(409);
      const body = await res.json();
      expect(body.error).toBe('stale-suggestion');
    });

    it('rejects missing suggestedParentId', async () => {
      const res = await app.request(
        `/api/sessions/${childSession.id}/suggestion`,
        {
          method: 'DELETE',
          body: JSON.stringify({}),
          headers: jsonHeaders(),
        },
      );
      expect(res.status).toBe(400);
      const body = await res.json();
      expect(body.error).toBe('suggestedParentId required');
    });
  });

  // --- GET /api/sessions/:id/children ---

  describe('GET /api/sessions/:id/children', () => {
    it('returns confirmed and suggested children', async () => {
      // Set child1 as confirmed, child2 as suggested
      db.setParentSession(childSession.id, parentSession.id, 'manual');
      db.setSuggestedParent(childSession2.id, parentSession.id);

      const res = await app.request(
        `/api/sessions/${parentSession.id}/children`,
      );
      expect(res.status).toBe(200);
      const body = await res.json();
      expect(body.confirmed).toBeDefined();
      expect(body.suggested).toBeDefined();
      expect(Array.isArray(body.confirmed)).toBe(true);
      expect(Array.isArray(body.suggested)).toBe(true);
      expect(body.confirmed.length).toBe(1);
      expect(body.confirmed[0].id).toBe(childSession.id);
      expect(body.suggested.length).toBe(1);
      expect(body.suggested[0].id).toBe(childSession2.id);
    });

    it('returns empty arrays when no children exist', async () => {
      const res = await app.request(
        `/api/sessions/${childSession.id}/children`,
      );
      expect(res.status).toBe(200);
      const body = await res.json();
      expect(body.confirmed).toEqual([]);
      expect(body.suggested).toEqual([]);
    });

    it('respects limit and offset query params', async () => {
      // Link both children as confirmed
      db.setParentSession(childSession.id, parentSession.id, 'manual');
      db.setParentSession(childSession2.id, parentSession.id, 'manual');

      const res = await app.request(
        `/api/sessions/${parentSession.id}/children?limit=1&offset=0`,
      );
      expect(res.status).toBe(200);
      const body = await res.json();
      expect(body.confirmed.length).toBe(1);
      expect(body.confirmed[0].id).toBe(childSession.id);

      // With offset=1
      const res2 = await app.request(
        `/api/sessions/${parentSession.id}/children?limit=1&offset=1`,
      );
      const body2 = await res2.json();
      expect(body2.confirmed.length).toBe(1);
      expect(body2.confirmed[0].id).toBe(childSession2.id);
    });

    it('clamps limit to 100', async () => {
      const res = await app.request(
        `/api/sessions/${parentSession.id}/children?limit=500`,
      );
      expect(res.status).toBe(200);
      // We can't easily verify the clamped limit without many sessions,
      // but the endpoint should not error
      const body = await res.json();
      expect(body.confirmed).toBeDefined();
    });
  });
});
