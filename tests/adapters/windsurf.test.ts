// tests/adapters/windsurf.test.ts

import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { afterEach, describe, expect, it } from 'vitest';
import { WindsurfAdapter } from '../../src/adapters/windsurf.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const FIXTURE_CACHE = join(__dirname, '../fixtures/windsurf/cache');

describe('WindsurfAdapter (cache mode)', () => {
  const adapter = new WindsurfAdapter('/nonexistent/daemon', FIXTURE_CACHE);

  it('name is windsurf', () => expect(adapter.name).toBe('windsurf'));

  it('listSessionFiles yields cache JSONL files', async () => {
    const files: string[] = [];
    for await (const f of adapter.listSessionFiles()) files.push(f);
    expect(files.some((f) => f.endsWith('conv-w01.jsonl'))).toBe(true);
  });

  it('parseSessionInfo reads from cache', async () => {
    const filePath = join(FIXTURE_CACHE, 'conv-w01.jsonl');
    const info = await adapter.parseSessionInfo(filePath);
    expect(info).not.toBeNull();
    expect(info?.source).toBe('windsurf');
    expect(info?.id).toBe('conv-w01');
  });

  it('streamMessages yields messages', async () => {
    const filePath = join(FIXTURE_CACHE, 'conv-w01.jsonl');
    const msgs: { role: string }[] = [];
    for await (const m of adapter.streamMessages(filePath)) msgs.push(m);
    expect(msgs).toHaveLength(2);
  });
});

describe('WindsurfAdapter cwd surfacing (R5-34)', () => {
  let tmp: string;
  afterEach(() => {
    if (tmp) rmSync(tmp, { recursive: true, force: true });
  });

  it('reads cwd from the cache meta line when present', async () => {
    tmp = mkdtempSync(join(tmpdir(), 'engram-windsurf-cwd-'));
    const filePath = join(tmp, 'conv-cwd.jsonl');
    const lines = [
      JSON.stringify({
        id: 'conv-cwd',
        title: 'X',
        createdAt: '2026-02-18T09:00:00.000Z',
        updatedAt: '2026-02-18T09:20:00.000Z',
        cwd: '/Users/test/proj',
      }),
      JSON.stringify({ role: 'user', content: 'hi' }),
    ].join('\n');
    writeFileSync(filePath, `${lines}\n`);
    const adapter = new WindsurfAdapter('/nonexistent/daemon', tmp);
    const info = await adapter.parseSessionInfo(filePath);
    expect(info?.cwd).toBe('/Users/test/proj');
  });

  it('falls back to empty cwd for legacy caches without the field', async () => {
    tmp = mkdtempSync(join(tmpdir(), 'engram-windsurf-nocwd-'));
    const filePath = join(tmp, 'conv-nocwd.jsonl');
    const lines = [
      JSON.stringify({
        id: 'conv-nocwd',
        title: 'X',
        createdAt: '2026-02-18T09:00:00.000Z',
        updatedAt: '2026-02-18T09:20:00.000Z',
      }),
      JSON.stringify({ role: 'user', content: 'hi' }),
    ].join('\n');
    writeFileSync(filePath, `${lines}\n`);
    const adapter = new WindsurfAdapter('/nonexistent/daemon', tmp);
    const info = await adapter.parseSessionInfo(filePath);
    expect(info?.cwd).toBe('');
  });
});
