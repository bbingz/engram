import { describe, expect, it } from 'vitest';
import {
  computeQualityScore,
  type ScoringInput,
} from '../../src/core/session-scoring.js';

function makeInput(overrides: Partial<ScoringInput> = {}): ScoringInput {
  return {
    userCount: 5,
    assistantCount: 5,
    toolCount: 3,
    systemCount: 1,
    startTime: '2024-01-01T10:00:00Z',
    endTime: '2024-01-01T10:30:00Z',
    project: 'my-project',
    ...overrides,
  };
}

describe('computeQualityScore()', () => {
  describe('turn ratio (0-30)', () => {
    it('scores 0 when userCount is 0', () => {
      const score = computeQualityScore(makeInput({ userCount: 0 }));
      // Turn ratio = 0 (no user messages)
      // Other factors still contribute
      const withUser = computeQualityScore(makeInput({ userCount: 5 }));
      expect(score).toBeLessThan(withUser);
    });

    it('scores 0 turn ratio when assistantCount is 0', () => {
      const score = computeQualityScore(makeInput({ assistantCount: 0 }));
      const withAssistant = computeQualityScore(
        makeInput({ assistantCount: 5 }),
      );
      expect(score).toBeLessThan(withAssistant);
    });

    it('rewards balanced user/assistant pairs', () => {
      // 5 user + 5 assistant = 5 pairs out of 14 total → (5/14)*30 ≈ 10.7
      const balanced = computeQualityScore(
        makeInput({ userCount: 5, assistantCount: 5 }),
      );
      // 1 user + 9 assistant = 1 pair out of 14 total → (1/14)*30 ≈ 2.1
      const unbalanced = computeQualityScore(
        makeInput({ userCount: 1, assistantCount: 9 }),
      );
      expect(balanced).toBeGreaterThan(unbalanced);
    });
  });

  describe('tool engagement (0-25)', () => {
    it('scores higher with more tool usage', () => {
      const highTool = computeQualityScore(makeInput({ toolCount: 10 }));
      const lowTool = computeQualityScore(makeInput({ toolCount: 1 }));
      expect(highTool).toBeGreaterThan(lowTool);
    });

    it('caps tool score at 25', () => {
      // toolCount/assistantCount * 50 → 100/5 * 50 = 1000 → capped at 25
      const extreme = computeQualityScore(
        makeInput({ toolCount: 100, assistantCount: 5 }),
      );
      const high = computeQualityScore(
        makeInput({ toolCount: 50, assistantCount: 5 }),
      );
      // Both should have the same tool score (capped at 25)
      // Difference comes only from turn ratio and volume changes
      expect(extreme).toBeGreaterThanOrEqual(high - 5); // within volume difference
    });

    it('scores 0 tool engagement when assistantCount is 0', () => {
      const score = computeQualityScore(
        makeInput({ assistantCount: 0, toolCount: 10 }),
      );
      // No assistant = 0 tool score (division guard)
      expect(score).toBeLessThan(50);
    });
  });

  describe('session density (0-20)', () => {
    it('scores 0 for sessions under 1 minute', () => {
      const score = computeQualityScore(
        makeInput({
          startTime: '2024-01-01T10:00:00Z',
          endTime: '2024-01-01T10:00:30Z',
        }),
      );
      const longer = computeQualityScore(
        makeInput({
          startTime: '2024-01-01T10:00:00Z',
          endTime: '2024-01-01T10:10:00Z',
        }),
      );
      expect(score).toBeLessThan(longer);
    });

    it('scores max density for 5-60 min sessions', () => {
      const fiveMin = computeQualityScore(
        makeInput({
          startTime: '2024-01-01T10:00:00Z',
          endTime: '2024-01-01T10:05:00Z',
        }),
      );
      const thirtyMin = computeQualityScore(
        makeInput({
          startTime: '2024-01-01T10:00:00Z',
          endTime: '2024-01-01T10:30:00Z',
        }),
      );
      const sixtyMin = computeQualityScore(
        makeInput({
          startTime: '2024-01-01T10:00:00Z',
          endTime: '2024-01-01T11:00:00Z',
        }),
      );
      // All should have density = 20
      expect(fiveMin).toBe(thirtyMin);
      expect(thirtyMin).toBe(sixtyMin);
    });

    it('tapers for sessions over 60 min', () => {
      const sixtyMin = computeQualityScore(
        makeInput({
          startTime: '2024-01-01T10:00:00Z',
          endTime: '2024-01-01T11:00:00Z',
        }),
      );
      const twoHours = computeQualityScore(
        makeInput({
          startTime: '2024-01-01T10:00:00Z',
          endTime: '2024-01-01T12:00:00Z',
        }),
      );
      expect(sixtyMin).toBeGreaterThan(twoHours);
    });

    it('scores 10 density for sessions over 3 hours', () => {
      const fourHours = computeQualityScore(
        makeInput({
          startTime: '2024-01-01T10:00:00Z',
          endTime: '2024-01-01T14:00:00Z',
        }),
      );
      const fiveHours = computeQualityScore(
        makeInput({
          startTime: '2024-01-01T10:00:00Z',
          endTime: '2024-01-01T15:00:00Z',
        }),
      );
      // Both should have density = 10 (plateau after 3h)
      expect(fourHours).toBe(fiveHours);
    });

    it('scores 0 density when timestamps missing', () => {
      const noTimes = computeQualityScore(
        makeInput({
          startTime: null,
          endTime: null,
        }),
      );
      const withTimes = computeQualityScore(
        makeInput({
          startTime: '2024-01-01T10:00:00Z',
          endTime: '2024-01-01T10:30:00Z',
        }),
      );
      expect(noTimes).toBeLessThan(withTimes);
    });
  });

  describe('project association (0-15)', () => {
    it('scores 15 for sessions with a project', () => {
      const withProject = computeQualityScore(
        makeInput({ project: 'my-project' }),
      );
      const noProject = computeQualityScore(makeInput({ project: null }));
      expect(withProject - noProject).toBe(15);
    });

    it('scores 0 for sessions without a project', () => {
      const noProject = computeQualityScore(makeInput({ project: null }));
      const withProject = computeQualityScore(makeInput({ project: 'x' }));
      expect(noProject).toBeLessThan(withProject);
    });
  });

  describe('message volume (0-10)', () => {
    it('rewards more messages up to cap', () => {
      const few = computeQualityScore(
        makeInput({ userCount: 1, assistantCount: 1, toolCount: 0 }),
      );
      const many = computeQualityScore(
        makeInput({ userCount: 10, assistantCount: 10, toolCount: 10 }),
      );
      expect(many).toBeGreaterThan(few);
    });

    it('caps volume at 10', () => {
      // 50 messages / 5 = 10 (cap)
      const fifty = computeQualityScore(
        makeInput({ userCount: 25, assistantCount: 25, toolCount: 0 }),
      );
      const hundred = computeQualityScore(
        makeInput({ userCount: 50, assistantCount: 50, toolCount: 0 }),
      );
      // Both should have volume = 10 (capped). Difference comes from turn ratio changes.
      expect(Math.abs(fifty - hundred)).toBeLessThanOrEqual(5);
    });
  });

  describe('edge cases', () => {
    it('returns 0 for empty session (all counts 0)', () => {
      const score = computeQualityScore({
        userCount: 0,
        assistantCount: 0,
        toolCount: 0,
        systemCount: 0,
      });
      expect(score).toBe(0);
    });

    it('floors at 0', () => {
      const score = computeQualityScore({
        userCount: 0,
        assistantCount: 0,
        toolCount: 0,
        systemCount: 0,
        startTime: null,
        endTime: null,
        project: null,
      });
      expect(score).toBeGreaterThanOrEqual(0);
    });

    it('caps at 100', () => {
      // Max possible: turn=30 + tool=25 + density=20 + project=15 + volume=10 = 100
      const score = computeQualityScore({
        userCount: 25,
        assistantCount: 25,
        toolCount: 25,
        systemCount: 0,
        startTime: '2024-01-01T10:00:00Z',
        endTime: '2024-01-01T10:30:00Z',
        project: 'big-project',
      });
      expect(score).toBeLessThanOrEqual(100);
      expect(score).toBeGreaterThan(50); // should be high
    });

    it('handles undefined timestamps gracefully', () => {
      const score = computeQualityScore(
        makeInput({
          startTime: undefined,
          endTime: undefined,
        }),
      );
      expect(score).toBeGreaterThanOrEqual(0);
      expect(score).toBeLessThanOrEqual(100);
    });

    it('returns a round number', () => {
      const score = computeQualityScore(makeInput());
      expect(Number.isInteger(score)).toBe(true);
    });
  });

  describe('overall scoring', () => {
    it('interactive project session scores higher than abandoned session', () => {
      const good = computeQualityScore({
        userCount: 10,
        assistantCount: 10,
        toolCount: 8,
        systemCount: 1,
        startTime: '2024-01-01T10:00:00Z',
        endTime: '2024-01-01T10:30:00Z',
        project: 'my-app',
      });
      const bad = computeQualityScore({
        userCount: 1,
        assistantCount: 0,
        toolCount: 0,
        systemCount: 0,
        startTime: '2024-01-01T10:00:00Z',
        endTime: '2024-01-01T10:00:10Z',
        project: null,
      });
      expect(good).toBeGreaterThan(bad);
      expect(good).toBeGreaterThan(60); // should be "high quality"
      expect(bad).toBeLessThan(10); // should be "low quality"
    });
  });
});
