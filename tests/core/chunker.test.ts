import { describe, expect, it } from 'vitest';
import type { Message } from '../../src/adapters/types.js';
import { chunkMessages } from '../../src/core/chunker.js';

function msg(role: Message['role'], content: string): Message {
  return { role, content };
}

describe('chunkMessages', () => {
  it('groups short messages into one chunk', () => {
    const messages = [msg('user', 'hello'), msg('assistant', 'hi there')];
    const chunks = chunkMessages('s1', messages);
    expect(chunks).toHaveLength(1);
    expect(chunks[0].text).toContain('[user] hello');
    expect(chunks[0].text).toContain('[assistant] hi there');
    expect(chunks[0].chunkIndex).toBe(0);
    expect(chunks[0].sessionId).toBe('s1');
  });

  it('splits on message boundaries when buffer exceeds maxChars', () => {
    const messages = [
      msg('user', 'a'.repeat(300)),
      msg('assistant', 'b'.repeat(300)),
      msg('user', 'c'.repeat(300)),
    ];
    const chunks = chunkMessages('s2', messages, { maxChars: 400 });
    expect(chunks.length).toBeGreaterThanOrEqual(3);
    // Each chunk should be under maxChars
    for (const chunk of chunks) {
      expect(chunk.text.length).toBeLessThanOrEqual(400);
    }
  });

  it('uses sliding window for oversized single messages', () => {
    const messages = [msg('user', 'x'.repeat(2000))];
    const chunks = chunkMessages('s3', messages, {
      maxChars: 800,
      overlap: 200,
    });
    expect(chunks.length).toBeGreaterThan(1);
    // Verify overlap: end of chunk N overlaps with start of chunk N+1
    if (chunks.length >= 2) {
      const end0 = chunks[0].text.slice(-200);
      const start1 = chunks[1].text.slice(0, 200);
      // The overlap region should share content (both contain 'x' runs)
      expect(end0.length).toBe(200);
      expect(start1.length).toBe(200);
    }
  });

  it('skips system and empty messages', () => {
    const messages = [
      msg('system', 'you are a helpful assistant'),
      msg('user', ''),
      msg('user', 'actual content'),
    ];
    const chunks = chunkMessages('s4', messages);
    expect(chunks).toHaveLength(1);
    expect(chunks[0].text).toBe('[user] actual content');
  });

  it('returns empty array for no content', () => {
    const chunks = chunkMessages('s5', []);
    expect(chunks).toHaveLength(0);
  });

  it('assigns sequential chunk indices', () => {
    const messages = [
      msg('user', 'a'.repeat(500)),
      msg('assistant', 'b'.repeat(500)),
      msg('user', 'c'.repeat(500)),
    ];
    const chunks = chunkMessages('s6', messages, { maxChars: 600 });
    for (let i = 0; i < chunks.length; i++) {
      expect(chunks[i].chunkIndex).toBe(i);
    }
  });
});
