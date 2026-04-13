import { randomUUID } from 'node:crypto';
import { chunkMessages } from './chunker.js';
import type { Database } from './db.js';
import type { EmbeddingClient } from './embeddings.js';
import type { PersistedIndexJob } from './session-snapshot.js';
import type { VectorStore } from './vector-store.js';

interface JobRunSummary {
  completed: number;
  notApplicable: number;
  failedRetryable: number;
}

export class IndexJobRunner {
  constructor(
    private db: Database,
    private store?: VectorStore,
    private client?: EmbeddingClient,
  ) {}

  async runRecoverableJobs(): Promise<JobRunSummary> {
    const jobs = this.db.takeRecoverableIndexJobs(50);
    const summary: JobRunSummary = {
      completed: 0,
      notApplicable: 0,
      failedRetryable: 0,
    };

    for (const job of jobs) {
      if (job.jobKind === 'fts') {
        this.runFtsJob(job);
      } else {
        await this.runEmbeddingJob(job);
      }
      const updated = this.db
        .listIndexJobs(job.sessionId)
        .find((j) => j.id === job.id);
      if (updated?.status === 'completed') summary.completed++;
      else if (updated?.status === 'not_applicable') summary.notApplicable++;
      else if (updated?.status === 'failed_retryable')
        summary.failedRetryable++;
    }

    return summary;
  }

  private runFtsJob(job: PersistedIndexJob): void {
    const snapshot = this.db.getAuthoritativeSnapshot(job.sessionId);
    if (!snapshot || snapshot.syncVersion !== job.targetSyncVersion) {
      this.db.markIndexJobCompleted(job.id);
      return;
    }

    // Preserve existing FTS content (full user/assistant messages indexed by Indexer).
    // Only rebuild if no existing content — avoid regressing from full messages to summary-only.
    const existing = this.db.getFtsContent(job.sessionId);
    if (existing.length > 0) {
      this.db.markIndexJobCompleted(job.id);
      return;
    }

    // Fallback: no existing FTS content, index metadata fields
    const searchableText = [
      snapshot.summary ?? '',
      snapshot.project ?? '',
      snapshot.model ?? '',
    ].filter(Boolean);
    if (searchableText.length > 0) {
      this.db.replaceFtsContent(job.sessionId, searchableText);
    }
    this.db.markIndexJobCompleted(job.id);
  }

  private async runEmbeddingJob(job: PersistedIndexJob): Promise<void> {
    const snapshot = this.db.getAuthoritativeSnapshot(job.sessionId);
    if (!snapshot || snapshot.syncVersion !== job.targetSyncVersion) {
      this.db.markIndexJobCompleted(job.id);
      return;
    }

    const local = this.db.getLocalState(job.sessionId);
    if (!local?.localReadablePath) {
      this.db.markIndexJobNotApplicable(job.id);
      return;
    }

    if (!this.store || !this.client) {
      // No embedding provider configured — leave job as pending for future retry
      // when provider becomes available, instead of permanently closing it.
      return;
    }

    try {
      const text = this.db
        .getFtsContent(job.sessionId)
        .join('\n')
        .slice(0, 8000);
      if (!text) {
        this.db.markIndexJobNotApplicable(job.id);
        return;
      }
      const embedding = await this.client.embed(text);
      if (!embedding) throw new Error('embedding unavailable');
      // Session-level embedding (legacy, kept for fast session ranking)
      this.store.upsert(job.sessionId, embedding, this.client.model);

      // Chunk-level embeddings (fine-grained retrieval)
      await this.indexChunks(job.sessionId, text);

      this.db.markIndexJobCompleted(job.id);
    } catch (err) {
      this.db.markIndexJobRetryableFailure(
        job.id,
        err instanceof Error ? err.message : String(err),
      );
    }
  }

  /** Promote text-only insights to embedded when a provider becomes available. */
  async backfillInsightEmbeddings(): Promise<number> {
    if (!this.store || !this.client) return 0;
    const unembedded = this.db.listUnembeddedInsights(20);
    let count = 0;
    for (const insight of unembedded) {
      try {
        const embedding = await this.client.embed(insight.content);
        if (embedding) {
          this.store.upsertInsight(
            insight.id,
            insight.content,
            embedding,
            this.client.model,
            {
              wing: insight.wing ?? undefined,
              room: insight.room ?? undefined,
              importance: insight.importance,
            },
          );
          this.db.markInsightEmbedded(insight.id);
          count++;
        }
      } catch {
        /* skip this insight, retry on next pass */
      }
    }
    return count;
  }

  private async indexChunks(sessionId: string, ftsText: string): Promise<void> {
    if (!this.store || !this.client) return;

    // Build pseudo-messages from FTS text lines for chunking
    const lines = ftsText.split('\n').filter(Boolean);
    const messages = lines.map((line) => ({
      role: 'assistant' as const,
      content: line,
    }));

    const chunks = chunkMessages(sessionId, messages);
    if (chunks.length === 0) return;

    // Embed each chunk
    const embeddings: Float32Array[] = [];
    const validChunks: {
      chunkId: string;
      sessionId: string;
      chunkIndex: number;
      text: string;
    }[] = [];

    for (const chunk of chunks) {
      const emb = await this.client.embed(chunk.text);
      if (emb) {
        embeddings.push(emb);
        validChunks.push({
          chunkId: `${sessionId}-c${chunk.chunkIndex}-${randomUUID().slice(0, 8)}`,
          sessionId: chunk.sessionId,
          chunkIndex: chunk.chunkIndex,
          text: chunk.text,
        });
      }
    }

    if (validChunks.length > 0) {
      this.store.upsertChunks(validChunks, embeddings, this.client.model);
    }
  }
}
