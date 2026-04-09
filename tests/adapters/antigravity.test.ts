// tests/adapters/antigravity.test.ts

import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { AntigravityAdapter } from '../../src/adapters/antigravity.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const FIXTURE_CACHE = join(__dirname, '../fixtures/antigravity/cache');

describe('AntigravityAdapter (cache mode)', () => {
  // Pass a non-existent daemon dir — adapter falls back to cache-only mode
  const adapter = new AntigravityAdapter('/nonexistent/daemon', FIXTURE_CACHE);

  it('name is antigravity', () => {
    expect(adapter.name).toBe('antigravity');
  });

  it('listSessionFiles yields cache JSONL files', async () => {
    const files: string[] = [];
    for await (const f of adapter.listSessionFiles()) files.push(f);
    expect(files.some((f) => f.endsWith('conv-001.jsonl'))).toBe(true);
  });

  it('parseSessionInfo reads metadata from first line', async () => {
    const filePath = join(FIXTURE_CACHE, 'conv-001.jsonl');
    const info = await adapter.parseSessionInfo(filePath);
    expect(info).not.toBeNull();
    expect(info?.id).toBe('conv-001');
    expect(info?.source).toBe('antigravity');
    expect(info?.summary).toContain('Fix auth bug');
  });

  it('streamMessages yields user and assistant from cache', async () => {
    const filePath = join(FIXTURE_CACHE, 'conv-001.jsonl');
    const msgs: { role: string; content: string }[] = [];
    for await (const m of adapter.streamMessages(filePath)) msgs.push(m);
    expect(msgs).toHaveLength(2);
    expect(msgs[0].role).toBe('user');
    expect(msgs[1].role).toBe('assistant');
  });
});
