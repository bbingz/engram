import { describe, expect, it } from 'vitest';
import {
  buildResumeCommand,
  buildResumeInspection,
} from '../../src/core/resume-coordinator.js';

describe('resume-coordinator', () => {
  it('builds claude resume command', () => {
    const result = buildResumeCommand(
      'claude-code',
      'session-abc',
      '/path/project',
    );
    // Either a ResumeCommand (if claude is installed) or ResumeError
    if ('command' in result) {
      expect(result.args).toContain('--resume');
      expect(result.args).toContain('session-abc');
      expect(result.cwd).toBe('/path/project');
    } else {
      expect(result.error).toContain('not found');
    }
  });

  it('returns open-directory fallback for cursor', () => {
    const result = buildResumeCommand('cursor', 'id', '/path');
    expect('command' in result).toBe(true);
    if ('command' in result) {
      expect(result.command).toBe('open');
      expect(result.args).toContain('Cursor');
    }
  });

  it('returns open fallback for unknown source', () => {
    const result = buildResumeCommand('unknown-tool', 'id', '/some/path');
    expect('command' in result).toBe(true);
    if ('command' in result) {
      expect(result.command).toBe('open');
      expect(result.args).toContain('/some/path');
    }
  });

  it('builds codex resume command using `codex resume <SESSION_ID>`', () => {
    const result = buildResumeCommand('codex', 'session-xyz', '/some/dir');
    if ('command' in result) {
      expect(result.tool).toBe('codex');
      expect(result.args).toEqual(['resume', 'session-xyz']);
      expect(result.args).not.toContain('--resume');
      expect(result.cwd).toBe('/some/dir');
    } else {
      expect(result.error).toContain('not found');
    }
  });

  it('builds gemini resume command', () => {
    const result = buildResumeCommand(
      'gemini-cli',
      'session-123',
      '/home/user/proj',
    );
    if ('command' in result) {
      expect(result.tool).toBe('gemini');
      expect(result.args).toContain('--resume');
      expect(result.args).toContain('session-123');
    } else {
      expect(result.error).toContain('not found');
    }
  });
});

describe('buildResumeInspection', () => {
  it('returns supported capability for codex with resolved command', () => {
    const result = buildResumeInspection('codex', 'session-xyz', '/some/dir', {
      resolveCommand: (cmd) => `/mock/bin/${cmd}`,
    });
    expect(result.capability).toBe('supported');
    expect(result.tool).toBe('codex');
    expect(result.command).toBe('/mock/bin/codex');
    expect(result.args).toEqual(['resume', 'session-xyz']);
    expect(result.cwd).toBe('/some/dir');
    expect(result.evidence).toBe('local_help');
  });

  it('returns supported capability for claude with --resume args', () => {
    const result = buildResumeInspection(
      'claude-code',
      'session-claude',
      '/p',
      { resolveCommand: (cmd) => `/mock/${cmd}` },
    );
    expect(result.capability).toBe('supported');
    expect(result.tool).toBe('claude');
    expect(result.args).toEqual(['--resume', 'session-claude']);
  });

  it('returns unsupported capability when CLI is not found', () => {
    const result = buildResumeInspection('codex', 'session-x', '/dir', {
      resolveCommand: () => null,
    });
    expect(result.capability).toBe('unsupported');
    expect(result.evidence).toBe('fallback');
    expect(result.warning).toContain('codex');
    expect(result.command).toBeUndefined();
  });

  it('does not invoke any resolver when opts is omitted', () => {
    const result = buildResumeInspection('codex', 'session-x', '/dir');
    expect(result.capability).toBe('unsupported');
    expect(result.tool).toBe('codex');
    expect(result.cwd).toBe('/dir');
    expect(result.evidence).toBe('fallback');
    expect(result.command).toBeUndefined();
    expect(result.args).toBeUndefined();
    expect(result.warning).toBeTruthy();
  });

  it('does not call the provided resolver when resolveCommand is missing', () => {
    let resolverCalls = 0;
    // omitting opts entirely: this is the spec — no PATH lookup.
    buildResumeInspection('claude-code', 'session-y', '/dir');
    // sanity check: when we DO pass a resolver, it is called.
    buildResumeInspection('claude-code', 'session-y', '/dir', {
      resolveCommand: (cmd) => {
        resolverCalls += 1;
        return `/mock/${cmd}`;
      },
    });
    expect(resolverCalls).toBe(1);
  });

  it('returns fallback for cursor source', () => {
    const result = buildResumeInspection('cursor', 'sid', '/wd', {
      resolveCommand: () => null,
    });
    expect(result.capability).toBe('fallback');
    expect(result.tool).toBe('cursor');
    expect(result.command).toBe('open');
    expect(result.args).toEqual(['-a', 'Cursor', '/wd']);
    expect(result.evidence).toBe('fallback');
  });

  it('returns fallback for unknown source', () => {
    const result = buildResumeInspection('lobsterai', 'sid', '/wd', {
      resolveCommand: () => null,
    });
    expect(result.capability).toBe('fallback');
    expect(result.evidence).toBe('fallback');
  });
});
