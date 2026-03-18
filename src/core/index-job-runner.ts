import type { Database } from './db.js'
import type { EmbeddingClient } from './embeddings.js'
import type { PersistedIndexJob } from './session-snapshot.js'
import type { VectorStore } from './vector-store.js'

export interface JobRunSummary {
  completed: number
  notApplicable: number
  failedRetryable: number
}

export class IndexJobRunner {
  constructor(
    private db: Database,
    private store?: VectorStore,
    private client?: EmbeddingClient,
  ) {}

  async runRecoverableJobs(): Promise<JobRunSummary> {
    const jobs = this.db.takeRecoverableIndexJobs(50)
    const summary: JobRunSummary = { completed: 0, notApplicable: 0, failedRetryable: 0 }

    for (const job of jobs) {
      if (job.jobKind === 'fts') {
        this.runFtsJob(job)
      } else {
        await this.runEmbeddingJob(job)
      }
      const updated = this.db.listIndexJobs(job.sessionId).find(j => j.id === job.id)
      if (updated?.status === 'completed') summary.completed++
      else if (updated?.status === 'not_applicable') summary.notApplicable++
      else if (updated?.status === 'failed_retryable') summary.failedRetryable++
    }

    return summary
  }

  private runFtsJob(job: PersistedIndexJob): void {
    const snapshot = this.db.getAuthoritativeSnapshot(job.sessionId)
    if (!snapshot || snapshot.syncVersion !== job.targetSyncVersion) {
      this.db.markIndexJobCompleted(job.id)
      return
    }

    const searchableText = [snapshot.summary ?? '', snapshot.project ?? '', snapshot.model ?? '']
      .filter(Boolean)
    this.db.replaceFtsContent(job.sessionId, searchableText)
    this.db.markIndexJobCompleted(job.id)
  }

  private async runEmbeddingJob(job: PersistedIndexJob): Promise<void> {
    const snapshot = this.db.getAuthoritativeSnapshot(job.sessionId)
    if (!snapshot || snapshot.syncVersion !== job.targetSyncVersion) {
      this.db.markIndexJobCompleted(job.id)
      return
    }

    const local = this.db.getLocalState(job.sessionId)
    if (!local?.localReadablePath) {
      this.db.markIndexJobNotApplicable(job.id)
      return
    }

    if (!this.store || !this.client) {
      this.db.markIndexJobNotApplicable(job.id)
      return
    }

    try {
      const text = this.db.getFtsContent(job.sessionId).join('\n').slice(0, 8000)
      if (!text) {
        this.db.markIndexJobNotApplicable(job.id)
        return
      }
      const embedding = await this.client.embed(text)
      if (!embedding) throw new Error('embedding unavailable')
      this.store.upsert(job.sessionId, embedding, this.client.model)
      this.db.markIndexJobCompleted(job.id)
    } catch (err) {
      this.db.markIndexJobRetryableFailure(job.id, String(err))
    }
  }
}
