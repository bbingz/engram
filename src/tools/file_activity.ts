// src/tools/file_activity.ts
import type { Database } from '../core/db.js'

export function handleFileActivity(db: Database, params: {
  project?: string
  since?: string
  limit?: number
}): { files: any[]; totalFiles: number } {
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
