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
  const preserveMessageCounts =
    incoming.messageCount === 0 && current.messageCount > 0;
  return {
    ...incoming,
    endTime: incoming.endTime ?? current.endTime,
    cwd: incoming.cwd === '' ? current.cwd : incoming.cwd,
    project: incoming.project ?? current.project,
    model: incoming.model ?? current.model,
    messageCount: preserveMessageCounts
      ? current.messageCount
      : incoming.messageCount,
    userMessageCount: preserveMessageCounts
      ? current.userMessageCount
      : incoming.userMessageCount,
    assistantMessageCount: preserveMessageCounts
      ? current.assistantMessageCount
      : incoming.assistantMessageCount,
    toolMessageCount: preserveMessageCounts
      ? current.toolMessageCount
      : incoming.toolMessageCount,
    systemMessageCount: preserveMessageCounts
      ? current.systemMessageCount
      : incoming.systemMessageCount,
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
    const currentTier = current.tier ?? 'normal';
    const incomingTier = incoming.tier ?? 'normal';
    const incomingSizeBytes = incoming.sizeBytes ?? current.sizeBytes;
    if (
      currentTier === incomingTier &&
      (current.agentRole ?? null) === (incoming.agentRole ?? null) &&
      current.sizeBytes === incomingSizeBytes
    ) {
      return {
        action: 'noop',
        merged: current,
        changeSet: { flags: new Set() },
      };
    }
  }

  const merged = coalesceSnapshot(current, incoming);

  const flags = new Set<ChangeFlag>(['sync_payload_changed']);
  const currentTier = current.tier ?? 'normal';
  const incomingTier = merged.tier ?? 'normal';

  if (
    currentTier !== incomingTier ||
    (current.agentRole ?? null) !== (merged.agentRole ?? null)
  ) {
    flags.add('local_state_changed');
  }

  if (currentTier === 'skip' && incomingTier !== 'skip') {
    flags.add('search_text_changed');
    if (incomingTier === 'normal' || incomingTier === 'premium') {
      flags.add('embedding_text_changed');
    }
  }

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
