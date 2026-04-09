import { describe, expect, it } from 'vitest';
import { computeTier, type TierInput } from '../../src/core/session-tier.js';

function makeInput(overrides: Partial<TierInput> = {}): TierInput {
  return {
    messageCount: 5,
    agentRole: null,
    filePath: '/home/user/.claude/projects/my-project/session.jsonl',
    project: null,
    summary: null,
    startTime: null,
    endTime: null,
    source: 'claude-code',
    ...overrides,
  };
}

describe('computeTier()', () => {
  describe('skip tier', () => {
    it('returns skip for agent session (agentRole set)', () => {
      expect(computeTier(makeInput({ agentRole: 'subagent' }))).toBe('skip');
    });

    it('returns skip for any non-null agentRole', () => {
      expect(computeTier(makeInput({ agentRole: 'orchestrator' }))).toBe(
        'skip',
      );
    });

    it('returns skip for subagent file path', () => {
      expect(
        computeTier(
          makeInput({
            filePath: '/home/user/.claude/projects/abc/subagents/xyz.jsonl',
          }),
        ),
      ).toBe('skip');
    });

    it('returns skip for messageCount 0', () => {
      expect(computeTier(makeInput({ messageCount: 0 }))).toBe('skip');
    });

    it('returns skip for messageCount 1', () => {
      expect(computeTier(makeInput({ messageCount: 1 }))).toBe('skip');
    });

    it('downgrades preamble-only to skip', () => {
      expect(
        computeTier(makeInput({ messageCount: 5, isPreamble: true })),
      ).toBe('skip');
    });

    it('downgrades probe sessions to skip', () => {
      expect(
        computeTier(
          makeInput({
            messageCount: 2,
            filePath: '/Users/x/.engram/probes/claude/session.jsonl',
          }),
        ),
      ).toBe('skip');
    });

    it('skip takes priority over premium (agent with 50 messages)', () => {
      expect(
        computeTier(makeInput({ agentRole: 'subagent', messageCount: 50 })),
      ).toBe('skip');
    });
  });

  describe('premium tier', () => {
    it('returns premium for messageCount exactly 20', () => {
      expect(computeTier(makeInput({ messageCount: 20 }))).toBe('premium');
    });

    it('returns premium for messageCount 25 with no project', () => {
      expect(computeTier(makeInput({ messageCount: 25, project: null }))).toBe(
        'premium',
      );
    });

    it('returns premium for messageCount 10 with project set', () => {
      expect(
        computeTier(makeInput({ messageCount: 10, project: 'my-project' })),
      ).toBe('premium');
    });

    it('returns premium for messageCount 15 with project set', () => {
      expect(
        computeTier(makeInput({ messageCount: 15, project: 'my-project' })),
      ).toBe('premium');
    });

    it('returns premium for 40-minute session', () => {
      const start = new Date('2024-01-01T10:00:00Z').toISOString();
      const end = new Date('2024-01-01T10:40:00Z').toISOString();
      expect(computeTier(makeInput({ startTime: start, endTime: end }))).toBe(
        'premium',
      );
    });

    it('premium takes priority over lite (/usage summary with 25 messages)', () => {
      expect(
        computeTier(
          makeInput({ messageCount: 25, summary: 'Check /usage stats' }),
        ),
      ).toBe('premium');
    });
  });

  describe('lite tier', () => {
    it('downgrades no-reply to lite', () => {
      expect(
        computeTier(
          makeInput({ messageCount: 3, assistantCount: 0, toolCount: 0 }),
        ),
      ).toBe('lite');
    });

    it('returns lite for /usage noise pattern in summary', () => {
      expect(computeTier(makeInput({ summary: 'Check /usage limits' }))).toBe(
        'lite',
      );
    });

    it('returns lite for auto-summary noise pattern', () => {
      expect(
        computeTier(
          makeInput({
            summary: 'Generate a short, clear title for this session',
          }),
        ),
      ).toBe('lite');
    });
  });

  describe('normal tier', () => {
    it('returns normal for exactly 30-minute session (not > 30)', () => {
      const start = new Date('2024-01-01T10:00:00Z').toISOString();
      const end = new Date('2024-01-01T10:30:00Z').toISOString();
      expect(computeTier(makeInput({ startTime: start, endTime: end }))).toBe(
        'normal',
      );
    });

    it('returns normal for messageCount 3, no project, clean summary', () => {
      expect(
        computeTier(
          makeInput({
            messageCount: 3,
            project: null,
            summary: 'Refactored auth module',
          }),
        ),
      ).toBe('normal');
    });

    it('returns normal for messageCount 8 with project (below premium threshold of 10)', () => {
      expect(
        computeTier(makeInput({ messageCount: 8, project: 'my-project' })),
      ).toBe('normal');
    });

    it('returns normal for messageCount 2, no summary', () => {
      expect(computeTier(makeInput({ messageCount: 2, summary: null }))).toBe(
        'normal',
      );
    });
  });

  describe('duration edge cases', () => {
    it('treats missing startTime as duration 0 (no premium from duration)', () => {
      const end = new Date('2024-01-01T10:40:00Z').toISOString();
      expect(computeTier(makeInput({ startTime: null, endTime: end }))).toBe(
        'normal',
      );
    });

    it('treats missing endTime as duration 0 (no premium from duration)', () => {
      const start = new Date('2024-01-01T10:00:00Z').toISOString();
      expect(computeTier(makeInput({ startTime: start, endTime: null }))).toBe(
        'normal',
      );
    });

    it('treats both timestamps missing as duration 0', () => {
      expect(computeTier(makeInput({ startTime: null, endTime: null }))).toBe(
        'normal',
      );
    });
  });
});
