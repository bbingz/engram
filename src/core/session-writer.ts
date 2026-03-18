import type { AuthoritativeSessionSnapshot } from './session-snapshot.js'
import type { Database } from './db.js'
import type { IndexJobKind } from './session-snapshot.js'
import { mergeSessionSnapshot } from './session-merge.js'

export interface SessionWriteResult {
  action: 'merge' | 'noop'
  changeSet: ReturnType<typeof mergeSessionSnapshot>['changeSet']
}

export class SessionSnapshotWriter {
  constructor(private db: Database) {}

  writeAuthoritativeSnapshot(snapshot: AuthoritativeSessionSnapshot): SessionWriteResult {
    const tx = this.db.getRawDb().transaction(() => {
      const current = this.db.getAuthoritativeSnapshot(snapshot.id)
      const mergeResult = mergeSessionSnapshot(current, snapshot)

      if (mergeResult.action === 'noop') {
        return {
          action: 'noop' as const,
          changeSet: mergeResult.changeSet,
        }
      }

      this.db.upsertAuthoritativeSnapshot(mergeResult.merged)

      const jobKinds: IndexJobKind[] = []
      if (mergeResult.changeSet.flags.has('search_text_changed')) jobKinds.push('fts')
      if (mergeResult.changeSet.flags.has('embedding_text_changed')) jobKinds.push('embedding')
      if (jobKinds.length > 0) {
        this.db.insertIndexJobs(snapshot.id, snapshot.syncVersion, jobKinds)
      }

      return {
        action: 'merge' as const,
        changeSet: mergeResult.changeSet,
      }
    })

    return tx()
  }
}
