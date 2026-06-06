import { describe, expect, it } from 'vitest';
import { mergeSessionSnapshot } from '../../src/core/session-merge.js';
import type { AuthoritativeSessionSnapshot } from '../../src/core/session-snapshot.js';

function makeSnapshot(
  overrides: Partial<AuthoritativeSessionSnapshot> = {},
): AuthoritativeSessionSnapshot {
  return {
    id: 'sess-1',
    source: 'codex',
    authoritativeNode: 'node-a',
    syncVersion: 1,
    snapshotHash: 'hash-1',
    indexedAt: '2026-03-18T12:00:00Z',
    sourceLocator: '/tmp/source.jsonl',
    startTime: '2026-03-18T11:00:00Z',
    cwd: '/repo',
    messageCount: 4,
    userMessageCount: 2,
    assistantMessageCount: 2,
    toolMessageCount: 0,
    systemMessageCount: 0,
    ...overrides,
  };
}

describe('session snapshot types', () => {
  it('accepts authoritative sync payload with version and hash', () => {
    const snapshot: AuthoritativeSessionSnapshot = makeSnapshot({
      syncVersion: 3,
      snapshotHash: 'abc123',
    });
    expect(snapshot.syncVersion).toBe(3);
  });
});

describe('mergeSessionSnapshot', () => {
  it('accepts newer sync version from the same authoritative node', () => {
    const result = mergeSessionSnapshot(
      makeSnapshot({ syncVersion: 1, snapshotHash: 'old', summary: 'old' }),
      makeSnapshot({ syncVersion: 2, snapshotHash: 'new', summary: 'new' }),
    );

    expect(result.action).toBe('merge');
    expect(result.changeSet.flags.has('sync_payload_changed')).toBe(true);
    expect(result.changeSet.flags.has('search_text_changed')).toBe(true);
  });

  it('rejects conflicting authoritative owner', () => {
    expect(() =>
      mergeSessionSnapshot(
        makeSnapshot({
          authoritativeNode: 'node-a',
          syncVersion: 2,
          snapshotHash: 'x',
        }),
        makeSnapshot({
          authoritativeNode: 'node-b',
          syncVersion: 3,
          snapshotHash: 'y',
        }),
      ),
    ).toThrow(/authoritative/i);
  });

  it('no-ops identical version and hash', () => {
    const result = mergeSessionSnapshot(
      makeSnapshot({ syncVersion: 2, snapshotHash: 'same' }),
      makeSnapshot({ syncVersion: 2, snapshotHash: 'same' }),
    );

    expect(result.action).toBe('noop');
    expect(result.changeSet.flags.size).toBe(0);
  });

  it('preserves populated optional fields when newer snapshot omits them', () => {
    const result = mergeSessionSnapshot(
      makeSnapshot({
        syncVersion: 1,
        snapshotHash: 'hash-1',
        project: 'engram',
        model: 'gpt-4o',
        summary: 'old summary',
      }),
      makeSnapshot({
        syncVersion: 2,
        snapshotHash: 'hash-2',
        project: undefined,
        model: undefined,
        summary: undefined,
      }),
    );

    expect(result.action).toBe('merge');
    expect(result.merged.project).toBe('engram');
    expect(result.merged.model).toBe('gpt-4o');
    expect(result.merged.summary).toBe('old summary');
  });

  it('preserves cwd and message counts when a newer parse is empty', () => {
    const result = mergeSessionSnapshot(
      makeSnapshot({
        syncVersion: 1,
        snapshotHash: 'hash-1',
        cwd: '/repo/engram',
        messageCount: 5,
        userMessageCount: 2,
        assistantMessageCount: 2,
        toolMessageCount: 1,
        systemMessageCount: 0,
      }),
      makeSnapshot({
        syncVersion: 2,
        snapshotHash: 'hash-2',
        cwd: '',
        messageCount: 0,
        userMessageCount: 0,
        assistantMessageCount: 0,
        toolMessageCount: 0,
        systemMessageCount: 0,
      }),
    );

    expect(result.action).toBe('merge');
    expect(result.merged.cwd).toBe('/repo/engram');
    expect(result.merged.messageCount).toBe(5);
    expect(result.merged.userMessageCount).toBe(2);
    expect(result.merged.assistantMessageCount).toBe(2);
    expect(result.merged.toolMessageCount).toBe(1);
    expect(result.merged.systemMessageCount).toBe(0);
    expect(result.changeSet.flags.has('embedding_text_changed')).toBe(false);
  });

  it('accepts equal syncVersion with different snapshot hash as a content refresh', () => {
    const result = mergeSessionSnapshot(
      makeSnapshot({ syncVersion: 2, snapshotHash: 'hash-a', summary: 'old' }),
      makeSnapshot({ syncVersion: 2, snapshotHash: 'hash-b', summary: 'new' }),
    );

    expect(result.action).toBe('merge');
    expect(result.merged.snapshotHash).toBe('hash-b');
    expect(result.changeSet.flags.has('search_text_changed')).toBe(true);
    expect(result.changeSet.flags.has('embedding_text_changed')).toBe(true);
  });
});
