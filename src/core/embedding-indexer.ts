import type BetterSqlite3 from 'better-sqlite3';
import type { Database } from './db.js';
import type { EmbeddingClient } from './embeddings.js';
import type { VectorStore } from './vector-store.js';

export class EmbeddingIndexer {
  private static readonly MAX_INDEXED_CACHE = 10_000;
  private indexed = new Set<string>();
  private embeddingExistsStmt: BetterSqlite3.Statement | null | undefined;

  constructor(
    private db: Database,
    private store: VectorStore,
    private client: EmbeddingClient,
  ) {}

  async indexAll(): Promise<number> {
    // Pre-populate from DB on first call to avoid re-embedding after restart
    if (this.indexed.size === 0) {
      try {
        const existing = this.db.raw
          .prepare('SELECT session_id FROM session_embeddings')
          .all() as { session_id: string }[];
        for (const row of existing) this.markIndexed(row.session_id);
      } catch {
        // Table may not exist yet if vector store hasn't initialized
      }
    }

    const BATCH_SIZE = 100;
    let count = 0;
    let offset = 0;

    while (true) {
      const sessions = this.db.listSessions({ limit: BATCH_SIZE, offset });
      if (sessions.length === 0) break;

      for (const session of sessions) {
        if (this.indexed.has(session.id)) continue;
        if (this.hasStoredEmbedding(session.id)) {
          this.markIndexed(session.id);
          continue;
        }

        const text = this.getSessionText(session.id);
        if (!text) {
          this.markIndexed(session.id);
          continue;
        }

        const embedding = await this.client.embed(text);
        if (!embedding) continue;

        this.store.upsert(session.id, embedding, this.client.model);
        this.markIndexed(session.id);
        count++;
      }

      offset += sessions.length;
      if (sessions.length < BATCH_SIZE) break;
    }

    return count;
  }

  async indexOne(sessionId: string): Promise<boolean> {
    const text = this.getSessionText(sessionId);
    if (!text) return false;

    const embedding = await this.client.embed(text);
    if (!embedding) return false;

    this.store.upsert(sessionId, embedding, this.client.model);
    this.markIndexed(sessionId);
    return true;
  }

  private markIndexed(sessionId: string): void {
    this.indexed.delete(sessionId);
    this.indexed.add(sessionId);
    while (this.indexed.size > EmbeddingIndexer.MAX_INDEXED_CACHE) {
      const oldest = this.indexed.values().next().value;
      if (oldest === undefined) break;
      this.indexed.delete(oldest);
    }
  }

  private hasStoredEmbedding(sessionId: string): boolean {
    if (this.embeddingExistsStmt === null) return false;

    try {
      this.embeddingExistsStmt ??= this.db.raw.prepare(
        'SELECT 1 AS found FROM session_embeddings WHERE session_id = ? LIMIT 1',
      );
      return Boolean(this.embeddingExistsStmt.get(sessionId));
    } catch {
      this.embeddingExistsStmt = null;
      return false;
    }
  }

  private getSessionText(sessionId: string): string | null {
    const rows = this.db.getFtsContent(sessionId);
    if (!rows || rows.length === 0) return null;
    const text = rows.join('\n').slice(0, 8000);
    return text.length > 0 ? text : null;
  }
}
