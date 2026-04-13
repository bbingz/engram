import { describe, expect, it } from 'vitest';
import {
  DISPATCH_PATTERNS,
  isDispatchPattern,
  pickBestCandidate,
  scoreCandidate,
} from '../../src/core/parent-detection.js';

describe('DISPATCH_PATTERNS', () => {
  it('exports a non-empty array of RegExp', () => {
    expect(DISPATCH_PATTERNS.length).toBeGreaterThan(0);
    for (const p of DISPATCH_PATTERNS) {
      expect(p).toBeInstanceOf(RegExp);
    }
  });
});

describe('isDispatchPattern', () => {
  it('<task> prefix returns true', () => {
    expect(isDispatchPattern('<task>Implement the feature</task>')).toBe(true);
  });

  it('<TASK> prefix returns true', () => {
    expect(isDispatchPattern('<TASK>Fix the bug</TASK>')).toBe(true);
  });

  it('"Your task is to" returns true', () => {
    expect(
      isDispatchPattern('Your task is to implement the sorting algorithm'),
    ).toBe(true);
  });

  it('"You are a...agent" returns true', () => {
    expect(
      isDispatchPattern('You are a code review agent for this project'),
    ).toBe(true);
  });

  it('"You are a...assistant" returns true', () => {
    expect(
      isDispatchPattern(
        'You are a helpful assistant that specializes in TypeScript',
      ),
    ).toBe(true);
  });

  it('"Review the following" returns true', () => {
    expect(
      isDispatchPattern('Review the following code for security issues'),
    ).toBe(true);
  });

  it('"Analyze the " returns true', () => {
    expect(isDispatchPattern('Analyze the implementation of this module')).toBe(
      true,
    );
  });

  it('"Analyze this " returns true', () => {
    expect(isDispatchPattern('Analyze this code for performance')).toBe(true);
  });

  it('normal user message returns false', () => {
    expect(isDispatchPattern('How do I fix the login page?')).toBe(false);
  });

  it('normal question returns false', () => {
    expect(isDispatchPattern('What does this function do?')).toBe(false);
  });

  it('empty string returns true (no summary = likely dispatched agent)', () => {
    expect(isDispatchPattern('')).toBe(true);
  });

  it('short string (< 10 chars) returns false', () => {
    expect(isDispatchPattern('Hi there')).toBe(false);
  });

  it('trims whitespace before matching', () => {
    expect(isDispatchPattern('  <task>Implement the feature</task>')).toBe(
      true,
    );
  });

  it('case insensitive for <task>', () => {
    expect(isDispatchPattern('<Task>Do the thing</Task>')).toBe(true);
  });
});

describe('scoreCandidate', () => {
  const base = '2026-04-13T10:00:00Z';
  const plus30s = '2026-04-13T10:00:30Z';
  const plus5m = '2026-04-13T10:05:00Z';
  const plus10m = '2026-04-13T10:10:00Z';
  const plus1h = '2026-04-13T11:00:00Z';
  const minus5m = '2026-04-13T09:55:00Z';

  it('returns 0 if agent started before parent', () => {
    expect(scoreCandidate(minus5m, base, plus1h, null, null)).toBe(0);
  });

  it('returns 0 if agent started after parent ended', () => {
    expect(scoreCandidate(plus1h, base, plus10m, null, null)).toBe(0);
  });

  it('closer start times score higher', () => {
    const closeScore = scoreCandidate(plus30s, base, null, null, null);
    const farScore = scoreCandidate(plus5m, base, null, null, null);
    expect(closeScore).toBeGreaterThan(farScore);
  });

  it('matching project scores higher', () => {
    const withProject = scoreCandidate(
      plus30s,
      base,
      null,
      'my-project',
      'my-project',
    );
    const noProject = scoreCandidate(plus30s, base, null, null, null);
    expect(withProject).toBeGreaterThan(noProject);
  });

  it('active session (no end_time) gets higher bonus', () => {
    const active = scoreCandidate(plus30s, base, null, null, null);
    const ended = scoreCandidate(plus30s, base, plus1h, null, null);
    expect(active).toBeGreaterThan(ended);
  });

  it('project match contributes 0.3 weight', () => {
    const withProject = scoreCandidate(plus30s, base, null, 'proj', 'proj');
    const noProject = scoreCandidate(plus30s, base, null, null, null);
    // Difference should be approximately 0.3 (exact project match weight)
    const diff = withProject - noProject;
    expect(diff).toBeCloseTo(0.3, 1);
  });

  it('active bonus difference is 0.05', () => {
    const active = scoreCandidate(plus30s, base, null, null, null);
    const ended = scoreCandidate(plus30s, base, plus1h, null, null);
    // Active = 1.0 * 0.1, ended = 0.5 * 0.1, diff = 0.05
    const diff = active - ended;
    expect(diff).toBeCloseTo(0.05, 2);
  });

  it('score is between 0 and 1', () => {
    const score = scoreCandidate(plus30s, base, null, 'proj', 'proj');
    expect(score).toBeGreaterThan(0);
    expect(score).toBeLessThanOrEqual(1);
  });

  it('mismatched projects get no project bonus', () => {
    const mismatch = scoreCandidate(
      plus30s,
      base,
      null,
      'project-a',
      'project-b',
    );
    const noProject = scoreCandidate(plus30s, base, null, null, null);
    expect(mismatch).toEqual(noProject);
  });

  it('one null project gets no project bonus', () => {
    const oneNull = scoreCandidate(plus30s, base, null, 'project-a', null);
    const noProject = scoreCandidate(plus30s, base, null, null, null);
    expect(oneNull).toEqual(noProject);
  });
});

describe('pickBestCandidate', () => {
  it('returns null for empty list', () => {
    expect(pickBestCandidate([])).toBeNull();
  });

  it('returns single candidate', () => {
    expect(pickBestCandidate([{ parentId: 'abc', score: 0.8 }])).toBe('abc');
  });

  it('returns null if best score is 0', () => {
    expect(
      pickBestCandidate([
        { parentId: 'a', score: 0 },
        { parentId: 'b', score: 0 },
      ]),
    ).toBeNull();
  });

  it('returns best candidate when clear winner (gap > 15%)', () => {
    expect(
      pickBestCandidate([
        { parentId: 'best', score: 0.9 },
        { parentId: 'second', score: 0.5 },
      ]),
    ).toBe('best');
  });

  it('returns null for ambiguous candidates (gap < 15%)', () => {
    expect(
      pickBestCandidate([
        { parentId: 'a', score: 0.8 },
        { parentId: 'b', score: 0.78 },
      ]),
    ).toBeNull();
  });

  it('returns best when gap is exactly 15%', () => {
    // gap = (0.80 - 0.68) / 0.80 = 0.15 exactly
    expect(
      pickBestCandidate([
        { parentId: 'winner', score: 0.8 },
        { parentId: 'loser', score: 0.68 },
      ]),
    ).toBe('winner');
  });

  it('handles more than 2 candidates', () => {
    expect(
      pickBestCandidate([
        { parentId: 'a', score: 0.3 },
        { parentId: 'b', score: 0.9 },
        { parentId: 'c', score: 0.5 },
      ]),
    ).toBe('b');
  });

  it('returns null when single candidate has score 0', () => {
    expect(pickBestCandidate([{ parentId: 'a', score: 0 }])).toBeNull();
  });
});
