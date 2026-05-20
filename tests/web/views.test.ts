import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import type { SourceName } from '../../src/adapters/types.js';
import { Database } from '../../src/core/db.js';
import { sessionDetailPage } from '../../src/web/views.js';
import { createApp } from '../../src/web.js';

type ClassificationCase = {
  name: string;
  source: SourceName;
  content: string;
  category: 'none' | 'systemPrompt' | 'agentComm';
};

const classificationCases = JSON.parse(
  readFileSync(
    join(
      process.cwd(),
      'macos/test-fixtures/transcript-display/system-classification-cases.json',
    ),
    'utf8',
  ),
) as ClassificationCase[];

describe('Web Views', () => {
  let db: Database;
  let tmpDir: string;
  let app: ReturnType<typeof createApp>;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), 'engram-views-test-'));
    db = new Database(join(tmpDir, 'test.sqlite'));
    app = createApp(db);
  });

  afterEach(() => {
    db.close();
    rmSync(tmpDir, { recursive: true });
  });

  it('GET / returns HTML with Engram layout', async () => {
    const res = await app.request('/');
    expect(res.status).toBe(200);
    expect(res.headers.get('content-type')).toContain('text/html');
    const html = await res.text();
    expect(html).toContain('Engram');
    expect(html).toContain('IBM Plex Sans');
  });

  it('GET /search returns HTML search page', async () => {
    const res = await app.request('/search');
    expect(res.status).toBe(200);
    const html = await res.text();
    expect(html).toContain('search');
  });

  it('GET /session/:id returns HTML detail', async () => {
    db.upsertSession({
      id: 'sess-1',
      source: 'codex',
      startTime: '2026-01-01T10:00:00Z',
      cwd: '/p',
      project: 'proj',
      messageCount: 5,
      userMessageCount: 2,
      assistantMessageCount: 0,
      toolMessageCount: 0,
      systemMessageCount: 0,
      summary: 'Test session',
      filePath: '/f1',
      sizeBytes: 100,
    });
    const res = await app.request('/session/sess-1');
    expect(res.status).toBe(200);
    const html = await res.text();
    expect(html).toContain('Test session');
    expect(html).toContain('Codex');
  });

  it('GET /session/:id returns 404 for missing session', async () => {
    const res = await app.request('/session/nonexistent');
    expect(res.status).toBe(404);
  });

  it('escapes XSS payloads in session summary and project', async () => {
    db.upsertSession({
      id: 'xss-1',
      source: 'codex',
      startTime: '2026-01-01T10:00:00Z',
      cwd: '/p',
      project: '<img onerror=alert(1)>',
      messageCount: 5,
      userMessageCount: 3,
      assistantMessageCount: 2,
      toolMessageCount: 0,
      systemMessageCount: 0,
      summary: '</title><script>alert("xss")</script>',
      filePath: '/f1',
      sizeBytes: 100,
    });

    // Session list page
    const listRes = await app.request('/');
    const listHtml = await listRes.text();
    expect(listHtml).not.toContain('<script>alert');
    expect(listHtml).toContain('&lt;script&gt;');

    // Session detail page
    const detailRes = await app.request('/session/xss-1');
    const detailHtml = await detailRes.text();
    expect(detailHtml).not.toContain('<script>alert');
    expect(detailHtml).toContain('&lt;script&gt;');
    // Title should also be escaped
    expect(detailHtml).toContain('<title>&lt;/title&gt;&lt;script&gt;');
  });

  it('renders subagent notifications as collapsed agent communication', () => {
    const html = sessionDetailPage(
      {
        id: 'subagent-note',
        source: 'codex',
        startTime: '2026-05-20T10:00:00Z',
        cwd: '/p',
        project: 'engram',
        messageCount: 1,
        userMessageCount: 1,
        assistantMessageCount: 0,
        toolMessageCount: 0,
        systemMessageCount: 0,
        summary: 'subagent notification',
        filePath: '/f1',
        sizeBytes: 100,
      },
      [
        {
          role: 'user',
          content:
            '<subagent_notification>\n{"agent_path":"agent-1","status":{"completed":"Result text"}}\n</subagent_notification>',
        },
      ],
    );

    expect(html).toContain('<strong>Agent Communication</strong>');
    expect(html).toContain('class="system-content"');
    expect(html).not.toContain(
      '<div class="role" style="color:var(--text-dim)">You</div>',
    );
  });

  it('renders AGENTS injected instructions as collapsed system prompt', () => {
    const html = sessionDetailPage(
      {
        id: 'agents-note',
        source: 'codex',
        startTime: '2026-05-20T10:00:00Z',
        cwd: '/p',
        project: 'engram',
        messageCount: 1,
        userMessageCount: 1,
        assistantMessageCount: 0,
        toolMessageCount: 0,
        systemMessageCount: 0,
        summary: 'agents instructions',
        filePath: '/f1',
        sizeBytes: 100,
      },
      [
        {
          role: 'user',
          content: '# AGENTS.md instructions for /Users/bing/-Code-/engram',
        },
      ],
    );

    expect(html).toContain('<strong>System Prompt</strong>');
    expect(html).toContain('class="system-content"');
    expect(html).not.toContain('<strong>Agent Communication</strong>');
  });

  it.each(
    classificationCases,
  )('keeps transcript display classification aligned with Swift for $name', ({
    source,
    content,
    category,
  }) => {
    const html = sessionDetailPage(
      {
        id: `case-${category}`,
        source,
        startTime: '2026-05-20T10:00:00Z',
        cwd: '/p',
        project: 'engram',
        messageCount: 1,
        userMessageCount: 1,
        assistantMessageCount: 0,
        toolMessageCount: 0,
        systemMessageCount: 0,
        summary: 'classification case',
        filePath: '/f1',
        sizeBytes: 100,
      },
      [{ role: 'user', content }],
    );

    if (category === 'systemPrompt') {
      expect(html).toContain('<strong>System Prompt</strong>');
      expect(html).not.toContain(
        '<div class="role" style="color:var(--text-dim)">You</div>',
      );
    } else if (category === 'agentComm') {
      expect(html).toContain('<strong>Agent Communication</strong>');
      expect(html).not.toContain(
        '<div class="role" style="color:var(--text-dim)">You</div>',
      );
    } else {
      expect(html).toContain(
        '<div class="role" style="color:var(--text-dim)">You</div>',
      );
      expect(html).not.toContain('<strong>System Prompt</strong>');
      expect(html).not.toContain('<strong>Agent Communication</strong>');
    }
  });
});
