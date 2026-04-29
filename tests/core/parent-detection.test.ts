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

  it('recognizes known probe messages', () => {
    expect(isDispatchPattern('say hi')).toBe(true);
    expect(isDispatchPattern('exit')).toBe(true);
    expect(isDispatchPattern('quit')).toBe(true);
    expect(isDispatchPattern('list-skills')).toBe(true);
  });

  it('matches math probe patterns with varying numbers', () => {
    expect(isDispatchPattern('What is 5+5?')).toBe(true);
    expect(isDispatchPattern('What is 1+1?')).toBe(true);
    expect(isDispatchPattern('what is 10 * 2?')).toBe(true);
    expect(isDispatchPattern('What is 100 - 7?')).toBe(true);
  });

  it('matches "say" probe variants', () => {
    expect(isDispatchPattern('Say hello in 3 words')).toBe(true);
    expect(isDispatchPattern('Say exactly: streaming works')).toBe(true);
    expect(isDispatchPattern('say: all fixes verified')).toBe(true);
  });

  it('does NOT treat ordinary "say more" follow-ups as agent probes', () => {
    expect(isDispatchPattern('Say more about vector search tradeoffs')).toBe(
      false,
    );
  });

  it('matches echo and reply probes', () => {
    expect(isDispatchPattern("echo 'hello'")).toBe(true);
    expect(isDispatchPattern('Reply with just the number')).toBe(true);
    expect(isDispatchPattern('Respond with only the answer')).toBe(true);
  });

  it('does NOT treat ordinary explanation questions as agent probes', () => {
    expect(
      isDispatchPattern('What is the meaning of this regex in auth.ts?'),
    ).toBe(false);
    expect(
      isDispatchPattern('Tell me the answer to why this test flakes'),
    ).toBe(false);
  });

  it('trims whitespace before matching', () => {
    expect(isDispatchPattern('  <task>Implement the feature</task>')).toBe(
      true,
    );
  });

  it('case insensitive for <task>', () => {
    expect(isDispatchPattern('<Task>Do the thing</Task>')).toBe(true);
  });

  it('matches embedded <task> blocks after a short preface', () => {
    expect(
      isDispatchPattern(
        'Frontend Code Quality & Security Review for the app.\n<task>Perform a focused review of the frontend code.</task>',
      ),
    ).toBe(true);
  });

  it('matches review-task prompts that start with "Review this"', () => {
    expect(
      isDispatchPattern(
        'Review this implementation plan for the project. Read the spec, inspect the diff, and report gaps.',
      ),
    ).toBe(true);
  });

  it('matches reviewer payload envelopes from delegated review flows', () => {
    expect(
      isDispatchPattern(
        '<user_action>\n<context>User initiated a review task.</context>\n<action>review</action>',
      ),
    ).toBe(true);
  });

  it('matches task verbs with technical context', () => {
    expect(isDispatchPattern('Fix the type error in services/auth.ts')).toBe(
      true,
    );
    expect(
      isDispatchPattern(
        'Debug the performance issue in the /api/search module',
      ),
    ).toBe(true);
    expect(
      isDispatchPattern(
        'Implement the caching component for the search function',
      ),
    ).toBe(true);
    expect(isDispatchPattern('Write tests for the database.ts module')).toBe(
      true,
    );
  });

  it('does NOT match bare task verbs without technical context', () => {
    expect(isDispatchPattern('Fix my lunch order')).toBe(false);
    expect(isDispatchPattern('Implement a strategy for growth')).toBe(false);
  });

  it('matches context preambles and instruction blocks', () => {
    expect(
      isDispatchPattern('Context: The user wants to refactor the auth module'),
    ).toBe(true);
    expect(isDispatchPattern('Instructions: Follow the spec below')).toBe(true);
    expect(
      isDispatchPattern(
        '<instructions>\nDo the following tasks...</instructions>',
      ),
    ).toBe(true);
    expect(isDispatchPattern('The following code needs to be reviewed')).toBe(
      true,
    );
  });

  it('matches role prompts for auditing and evaluation sessions', () => {
    expect(
      isDispatchPattern(
        'You are auditing the authentication flow of the service. Review the codebase and identify security issues.',
      ),
    ).toBe(true);
    expect(
      isDispatchPattern(
        'You are evaluating the Engram project on branch feat/local-semantic-search.',
      ),
    ).toBe(true);
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

  it('long-running parent still gets meaningful score', () => {
    // Parent started 2 hours ago but is still running
    const agentStart = '2026-04-13T12:00:00Z';
    const parentStart = '2026-04-13T10:00:00Z'; // 2h ago
    const score = scoreCandidate(
      agentStart,
      parentStart,
      null, // still running
      'my-project',
      'my-project',
    );
    // With 4h half-life: time ≈ 0.37, project = 0.3, active = 0.1 → ~0.77
    expect(score).toBeGreaterThan(0.5);
  });

  it('prefers exact cwd match over a closer unrelated cwd', () => {
    const agentStart = '2026-04-13T11:17:10Z';
    const exactCwdParent = scoreCandidate(
      agentStart,
      '2026-04-13T10:46:20Z',
      '2026-04-13T14:07:07Z',
      null,
      null,
      '/Users/example/-Code-/gemini-plugin-cc',
      '/Users/example/-Code-/gemini-plugin-cc',
    );
    const unrelatedCloserParent = scoreCandidate(
      agentStart,
      '2026-04-13T11:10:02Z',
      '2026-04-13T13:24:03Z',
      null,
      null,
      '/Users/example/-Code-/gemini-plugin-cc',
      '/Users/example/-Code-/sscms-audit',
    );

    expect(exactCwdParent).toBeGreaterThan(unrelatedCloserParent);
  });

  it('scores > 0 when parent ended before agent with same CWD (gap < 4h)', () => {
    // Parent ended at 11:48, agent started at 15:43 — 3h55m gap, same CWD
    const score = scoreCandidate(
      '2026-04-08T15:43:00Z',
      '2026-04-08T11:42:44Z',
      '2026-04-08T11:48:17Z',
      'Zhiwei',
      null,
      '/Users/example/-Code-/Zhiwei',
      '/Users/example/-Code-/Zhiwei',
    );
    expect(score).toBeGreaterThan(0);
  });

  it('returns 0 when parent ended before agent with unrelated CWD', () => {
    const score = scoreCandidate(
      '2026-04-08T15:43:00Z',
      '2026-04-08T11:42:44Z',
      '2026-04-08T11:48:17Z',
      null,
      null,
      '/Users/example/-Code-/Zhiwei',
      '/Users/example/-Code-/sscms-audit',
    );
    expect(score).toBe(0);
  });

  it('returns 0 when parent ended > 4h before agent even with same CWD', () => {
    const score = scoreCandidate(
      '2026-04-08T16:00:00Z',
      '2026-04-08T10:00:00Z',
      '2026-04-08T11:00:00Z', // 5h gap
      null,
      null,
      '/Users/example/-Code-/Zhiwei',
      '/Users/example/-Code-/Zhiwei',
    );
    expect(score).toBe(0);
  });

  it('penalizes unrelated cwd candidates when both sides provide cwd', () => {
    const agentStart = '2026-04-13T11:17:10Z';
    const unknownCwd = scoreCandidate(
      agentStart,
      '2026-04-13T11:10:02Z',
      null,
      null,
      null,
    );
    const unrelatedCwd = scoreCandidate(
      agentStart,
      '2026-04-13T11:10:02Z',
      null,
      null,
      null,
      '/Users/example/-Code-/gemini-plugin-cc',
      '/Users/example/-Code-/sscms-audit',
    );

    expect(unrelatedCwd).toBeLessThan(unknownCwd);
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

  it('returns best even for close candidates (prefers suggestion over none)', () => {
    // Two nearly identical scores — still picks the best one
    expect(
      pickBestCandidate([
        { parentId: 'a', score: 0.8 },
        { parentId: 'b', score: 0.78 },
      ]),
    ).toBe('a');
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
