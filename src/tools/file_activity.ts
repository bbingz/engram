// src/tools/file_activity.ts
import type { Database } from '../core/db.js'
import type { Logger } from '../core/logger.js'

export function handleFileActivity(db: Database, params: {
  project?: string
  since?: string
  limit?: number
}, opts?: { log?: Logger }): { files: any[]; totalFiles: number } {
  opts?.log?.info('file_activity invoked', { project: params.project, since: params.since })
  const files = db.getFileActivity({
    project: params.project,
    since: params.since,
    limit: params.limit ?? 50,
  })
  return {
    files,
    totalFiles: files.length,
  }
}
