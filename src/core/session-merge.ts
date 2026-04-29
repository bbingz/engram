import type {
  AuthoritativeSessionSnapshot,
  ChangeFlag,
  SessionChangeSet,
} from './session-snapshot.js';

function buildSearchText(snapshot: AuthoritativeSessionSnapshot): string {
  return [
    snapshot.summary ?? '',
    snapshot.project ?? '',
    snapshot.model ?? '',
  ].join('\n');
}

function buildEmbeddingText(snapshot: AuthoritativeSessionSnapshot): string {
  return [snapshot.summary ?? '', String(snapshot.messageCount)].join('\n');
}

function coalesceSnapshot(
  current: AuthoritativeSessionSnapshot,
  incoming: AuthoritativeSessionSnapshot,
): AuthoritativeSessionSnapshot {
  return {
    ...incoming,
    endTime: incoming.endTime ?? current.endTime,
    project: incoming.project ?? current.project,
    model: incoming.model ?? current.model,
    summary: incoming.summary ?? current.summary,
    summaryMessageCount:
      incoming.summaryMessageCount ?? current.summaryMessageCount,
    origin: incoming.origin ?? current.origin,
  };
}

export function mergeSessionSnapshot(
  current: AuthoritativeSessionSnapshot | null,
  incoming: AuthoritativeSessionSnapshot,
): {
  action: 'merge' | 'noop';
  merged: AuthoritativeSessionSnapshot;
  changeSet: SessionChangeSet;
} {
  if (!current) {
    return {
      action: 'merge',
      merged: incoming,
      changeSet: {
        flags: new Set([
          'sync_payload_changed',
          'search_text_changed',
          'embedding_text_changed',
        ]),
      },
    };
  }

  if (current.authoritativeNode !== incoming.authoritativeNode) {
    throw new Error(
      `Conflicting authoritative node for session ${incoming.id}`,
    );
  }

  if (incoming.syncVersion < current.syncVersion) {
    return { action: 'noop', merged: current, changeSet: { flags: new Set() } };
  }

  if (
    incoming.syncVersion === current.syncVersion &&
    incoming.snapshotHash === current.snapshotHash
  ) {
    return { action: 'noop', merged: current, changeSet: { flags: new Set() } };
  }

  if (
    incoming.syncVersion === current.syncVersion &&
    incoming.snapshotHash !== current.snapshotHash
  ) {
    throw new Error(
      `Conflicting snapshot hash for session ${incoming.id} at syncVersion ${incoming.syncVersion}`,
    );
  }

  const merged = coalesceSnapshot(current, incoming);

  const flags = new Set<ChangeFlag>(['sync_payload_changed']);

  if (buildSearchText(current) !== buildSearchText(merged)) {
    flags.add('search_text_changed');
  }

  if (buildEmbeddingText(current) !== buildEmbeddingText(merged)) {
    flags.add('embedding_text_changed');
  }

  return {
    action: 'merge',
    merged,
    changeSet: { flags },
  };
}
