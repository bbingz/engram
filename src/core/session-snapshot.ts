import type { SourceName } from '../adapters/types.js'

export interface AuthoritativeSessionSnapshot {
  id: string
  source: SourceName
  authoritativeNode: string
  syncVersion: number
  snapshotHash: string
  indexedAt: string
  sourceLocator: string
  startTime: string
  endTime?: string
  cwd: string
  project?: string
  model?: string
  messageCount: number
  userMessageCount: number
  assistantMessageCount: number
  toolMessageCount: number
  systemMessageCount: number
  summary?: string
  summaryMessageCount?: number
  origin?: string
}

export interface SessionLocalState {
  sessionId: string
  hiddenAt?: string
  customName?: string
  localReadablePath?: string
}

export type ChangeFlag =
  | 'sync_payload_changed'
  | 'search_text_changed'
  | 'embedding_text_changed'
  | 'local_state_changed'

export interface SessionChangeSet {
  flags: Set<ChangeFlag>
}

export interface SessionWriteResult {
  action: 'merge' | 'noop'
  changeSet: SessionChangeSet
}

export type IndexJobKind = 'fts' | 'embedding'
export type IndexJobStatus = 'pending' | 'running' | 'failed_retryable' | 'completed' | 'not_applicable'

export interface PersistedIndexJob {
  id: string
  sessionId: string
  jobKind: IndexJobKind
  targetSyncVersion: number
  status: IndexJobStatus
  retryCount: number
  lastError?: string
  createdAt: string
  updatedAt: string
}

export interface SyncCursor {
  indexedAt: string
  sessionId: string
}
