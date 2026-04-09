import { describe, expect, it, vi } from 'vitest';
import type { VikingBridge } from '../../src/core/viking-bridge.js';
import { handleGetMemory } from '../../src/tools/get_memory.js';

describe('handleGetMemory', () => {
  it('returns memories from Viking', async () => {
    const mockViking = {
      checkAvailable: vi.fn().mockResolvedValue(true),
      findMemories: vi.fn().mockResolvedValue([
        {
          content: 'User prefers TypeScript',
          source: 'session-1',
          confidence: 0.9,
          createdAt: '2026-03-16',
        },
      ]),
    } as unknown as VikingBridge;
    const result = await handleGetMemory(
      { query: 'coding style' },
      { viking: mockViking },
    );
    expect(result.memories).toHaveLength(1);
    expect(result.memories[0].content).toBe('User prefers TypeScript');
  });

  it('returns helpful message when Viking is not available', async () => {
    const result = await handleGetMemory({ query: 'coding style' }, {});
    expect(result.message).toContain('OpenViking');
  });
});
