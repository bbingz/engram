// tests/core/project-move/retry-policy.test.ts
//
// Guards the single source of truth for error → retry_policy +
// HTTP-status mapping + structured-details passthrough. Round 4
// extracted this module specifically because MCP and HTTP had drifted;
// these tests lock in the contract so the next drift will fail CI.

import { describe, expect, it } from 'vitest';
import {
  ConcurrentModificationError,
  InvalidUtf8Error,
} from '../../../src/core/project-move/jsonl-patch.js';
import { LockBusyError } from '../../../src/core/project-move/lock.js';
import {
  DirCollisionError,
  SharedEncodingCollisionError,
} from '../../../src/core/project-move/orchestrator.js';
import {
  buildErrorEnvelope,
  classifyRetryPolicy,
  humanizeForMcp,
  mapErrorStatus,
  sanitizeProjectMoveMessage,
} from '../../../src/core/project-move/retry-policy.js';
import {
  UndoNotAllowedError,
  UndoStaleError,
} from '../../../src/core/project-move/undo.js';

describe('classifyRetryPolicy', () => {
  it('LockBusy → wait', () => {
    expect(classifyRetryPolicy('LockBusyError')).toBe('wait');
  });
  it('ConcurrentModification → conditional', () => {
    expect(classifyRetryPolicy('ConcurrentModificationError')).toBe(
      'conditional',
    );
  });
  it('terminal errors → never', () => {
    for (const name of [
      'DirCollisionError',
      'SharedEncodingCollisionError',
      'UndoStaleError',
      'UndoNotAllowedError',
      'InvalidUtf8Error',
    ]) {
      expect(classifyRetryPolicy(name)).toBe('never');
    }
  });
  it('unknown errors default to never (not safe)', () => {
    // Round 4 Critical: MCP defaulted to 'never', HTTP defaulted to
    // 'safe'. Unifying here; client should NOT auto-retry an unknown
    // error — let the user decide.
    expect(classifyRetryPolicy('SomeRandomError')).toBe('never');
    expect(classifyRetryPolicy(undefined)).toBe('never');
  });
});

describe('mapErrorStatus', () => {
  it('conflict classes → 409', () => {
    for (const name of [
      'LockBusyError',
      'DirCollisionError',
      'SharedEncodingCollisionError',
      'UndoNotAllowedError',
      'UndoStaleError',
    ]) {
      expect(mapErrorStatus(name)).toBe(409);
    }
  });
  it('everything else → 500', () => {
    expect(mapErrorStatus('Error')).toBe(500);
    expect(mapErrorStatus('ConcurrentModificationError')).toBe(500);
    expect(mapErrorStatus(undefined)).toBe(500);
  });
});

describe('sanitizeProjectMoveMessage', () => {
  it('strips orchestrator prefix', () => {
    expect(sanitizeProjectMoveMessage('project-move: foo')).toBe('foo');
    expect(sanitizeProjectMoveMessage('runProjectMove: bar')).toBe('bar');
  });
  it('humanizes ENOENT / EACCES / EEXIST', () => {
    expect(
      sanitizeProjectMoveMessage(
        "Error: ENOENT: no such file, open '/tmp/foo'",
      ),
    ).toMatch(/File or directory not found: \/tmp\/foo/);
    expect(
      sanitizeProjectMoveMessage(
        "Error: EACCES: permission denied, rename '/tmp/a'",
      ),
    ).toMatch(/Permission denied: \/tmp\/a/);
  });
  it('preserves commas inside quoted paths', () => {
    // Round 4: reviewer Minor #2 — the old regex stopped at the first
    // comma, which would truncate paths like /tmp/file,with,commas.txt.
    // The fixed pattern greedily consumes up to a closing single-quote.
    const input = "Error: ENOENT: no such file, open '/tmp/odd,name.txt'";
    const result = sanitizeProjectMoveMessage(input);
    expect(result).toContain('/tmp/odd,name.txt');
  });
  it('leaves unknown messages untouched', () => {
    expect(sanitizeProjectMoveMessage('just a regular error')).toBe(
      'just a regular error',
    );
  });
});

describe('buildErrorEnvelope — structured details passthrough', () => {
  it('DirCollisionError exposes sourceId + dir paths via details', () => {
    const err = new DirCollisionError('claude-code', '/a/old', '/a/new');
    const env = buildErrorEnvelope(err);
    expect(env.error.name).toBe('DirCollisionError');
    expect(env.error.retry_policy).toBe('never');
    expect(env.error.details?.sourceId).toBe('claude-code');
    expect(env.error.details?.oldDir).toBe('/a/old');
    expect(env.error.details?.newDir).toBe('/a/new');
  });

  it('SharedEncodingCollisionError exposes sourceId + shared cwds', () => {
    const err = new SharedEncodingCollisionError('gemini-cli', '/proj', [
      '/a/proj',
      '/b/proj',
    ]);
    const env = buildErrorEnvelope(err);
    expect(env.error.name).toBe('SharedEncodingCollisionError');
    expect(env.error.details?.sourceId).toBe('gemini-cli');
    expect(env.error.details?.oldDir).toBe('/proj');
    expect(env.error.details?.sharingCwds).toEqual(['/a/proj', '/b/proj']);
  });

  it('UndoNotAllowedError exposes migrationId + state', () => {
    const err = new UndoNotAllowedError('m-42', 'failed');
    const env = buildErrorEnvelope(err);
    expect(env.error.name).toBe('UndoNotAllowedError');
    expect(env.error.details?.migrationId).toBe('m-42');
    expect(env.error.details?.state).toBe('failed');
  });

  it('plain errors omit details', () => {
    const err = new Error('generic');
    const env = buildErrorEnvelope(err);
    expect(env.error.details).toBeUndefined();
  });

  it('sanitize: true applies when requested', () => {
    const env = buildErrorEnvelope(new Error('project-move: bad thing'), {
      sanitize: true,
    });
    expect(env.error.message).toBe('bad thing');
  });

  it('sanitize: false preserves raw message (MCP path)', () => {
    const env = buildErrorEnvelope(new Error('project-move: bad thing'), {
      sanitize: false,
    });
    expect(env.error.message).toBe('project-move: bad thing');
  });
});

describe('humanizeForMcp — AI guidance', () => {
  it('all known error classes have dedicated humanText', () => {
    for (const err of [
      new LockBusyError({ pid: 1, migrationId: 'x', startedAt: 'now' }),
      new ConcurrentModificationError('/f', 1000, 2000),
      new UndoStaleError('m', 'reason'),
      new UndoNotAllowedError('m', 'failed'),
      new InvalidUtf8Error('bad'),
      new DirCollisionError('claude-code', '/a', '/b'),
      new SharedEncodingCollisionError('gemini-cli', '/p', ['/x']),
    ]) {
      const text = humanizeForMcp(err);
      // Must include both guidance (multi-line) and the raw message.
      expect(text.length).toBeGreaterThan(err.message.length);
      expect(text).toContain(err.message);
    }
  });

  it('DirCollisionError references details.newDir in guidance', () => {
    const text = humanizeForMcp(
      new DirCollisionError('claude-code', '/a', '/b'),
    );
    expect(text).toMatch(/target directory already exists/i);
  });

  it('unknown errors fall through to name: message', () => {
    const err = new Error('unexpected');
    err.name = 'SomeWeirdError';
    expect(humanizeForMcp(err)).toBe('SomeWeirdError: unexpected');
  });
});
