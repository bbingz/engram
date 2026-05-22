// tests/tools/message-loader.test.ts

import { describe, expect, it } from 'vitest';
import { loadBoundedMessages } from '../../src/tools/message-loader.js';

async function* gen(count: number, contentLen = 5) {
  for (let i = 0; i < count; i++) {
    yield {
      role: i % 2 === 0 ? 'user' : 'assistant',
      content: 'x'.repeat(contentLen),
      timestamp: `t${i}`,
    };
  }
}

describe('loadBoundedMessages', () => {
  it('returns all messages when under the cap', async () => {
    const res = await loadBoundedMessages(gen(10), { head: 100, tail: 100 });
    expect(res.totalSeen).toBe(10);
    expect(res.messages).toHaveLength(10);
    expect(res.truncated).toBe(false);
  });

  it('keeps head + tail and drops the middle for huge sessions', async () => {
    const res = await loadBoundedMessages(gen(1000), { head: 3, tail: 3 });
    expect(res.totalSeen).toBe(1000);
    expect(res.messages).toHaveLength(6);
    expect(res.truncated).toBe(true);
    // Head is the first 3, tail is the last 3 — in chronological order.
    expect(res.messages.map((m) => m.timestamp)).toEqual([
      't0',
      't1',
      't2',
      't997',
      't998',
      't999',
    ]);
  });

  it('truncates oversized per-message content', async () => {
    const res = await loadBoundedMessages(gen(1, 100), {
      head: 10,
      tail: 0,
      maxContentChars: 20,
    });
    expect(res.messages[0].content).toBe(`${'x'.repeat(20)}...`);
  });

  it('handles tail=0 (head-only sampling)', async () => {
    const res = await loadBoundedMessages(gen(100), { head: 5, tail: 0 });
    expect(res.messages).toHaveLength(5);
    expect(res.messages.map((m) => m.timestamp)).toEqual([
      't0',
      't1',
      't2',
      't3',
      't4',
    ]);
    expect(res.truncated).toBe(true);
  });
});
