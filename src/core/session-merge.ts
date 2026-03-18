import type { AuthoritativeSessionSnapshot } from './session-snapshot.js'

export type ChangeFlag =
  | 'sync_payload_changed'
  | 'search_text_changed'
  | 'embedding_text_changed'
  | 'local_state_changed'

export interface SessionChangeSet {
  flags: Set<ChangeFlag>
}

function buildSearchText(snapshot: AuthoritativeSessionSnapshot): string {
  return [snapshot.summary ?? '', snapshot.project ?? '', snapshot.model ?? ''].join('\n')
}

function buildEmbeddingText(snapshot: AuthoritativeSessionSnapshot): string {
  return [snapshot.summary ?? '', String(snapshot.messageCount)].join('\n')
}

export function mergeSessionSnapshot(
  current: AuthoritativeSessionSnapshot | null,
  incoming: AuthoritativeSessionSnapshot,
): { action: 'merge' | 'noop'; merged: AuthoritativeSessionSnapshot; changeSet: SessionChangeSet } {
  if (!current) {
    return {
      action: 'merge',
      merged: incoming,
      changeSet: {
        flags: new Set(['sync_payload_changed', 'search_text_changed', 'embedding_text_changed']),
      },
    }
  }

  if (current.authoritativeNode !== incoming.authoritativeNode) {
    throw new Error(`Conflicting authoritative node for session ${incoming.id}`)
  }

  if (incoming.syncVersion < current.syncVersion) {
    return { action: 'noop', merged: current, changeSet: { flags: new Set() } }
  }

  if (incoming.syncVersion === current.syncVersion && incoming.snapshotHash === current.snapshotHash) {
    return { action: 'noop', merged: current, changeSet: { flags: new Set() } }
  }

  const flags = new Set<ChangeFlag>(['sync_payload_changed'])

  if (buildSearchText(current) !== buildSearchText(incoming)) {
    flags.add('search_text_changed')
  }

  if (buildEmbeddingText(current) !== buildEmbeddingText(incoming)) {
    flags.add('embedding_text_changed')
  }

  return {
    action: 'merge',
    merged: incoming,
    changeSet: { flags },
  }
}
