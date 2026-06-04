import { describe, expect, it } from 'vitest';
import {
  formatResumeCommand,
  selectProjectSessions,
} from '../../src/cli/resume.js';

describe('selectProjectSessions', () => {
  it('keeps sessions for the current cwd or project and maps display fields', () => {
    const sessions = selectProjectSessions(
      [
        {
          id: 'session-with-custom-name',
          source: 'codex',
          cwd: '/repo/engram',
          project: 'engram',
          custom_name: 'Custom title',
          message_count: 5,
          start_time: '2026-06-01T10:00:00.000Z',
        },
        {
          id: 'session-with-project-match',
          source: 'claude-code',
          cwd: '/other/path',
          project: 'engram',
          summary: 'Project match summary',
        },
        {
          id: 'session-from-other-project',
          source: 'gemini-cli',
          cwd: '/other/project',
          project: 'other',
        },
      ],
      '/repo/engram',
    );

    expect(sessions).toEqual([
      {
        id: 'session-with-custom-name',
        source: 'codex',
        displayTitle: 'Custom title',
        messageCount: 5,
        startTime: '2026-06-01T10:00:00.000Z',
      },
      {
        id: 'session-with-project-match',
        source: 'claude-code',
        displayTitle: 'Project match summary',
        messageCount: 0,
        startTime: '',
      },
    ]);
  });
});

describe('formatResumeCommand', () => {
  it('joins the executable and args for display', () => {
    expect(formatResumeCommand('codex', ['--resume', 'abc123'])).toBe(
      'codex --resume abc123',
    );
  });
});
