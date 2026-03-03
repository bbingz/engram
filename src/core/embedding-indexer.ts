import type { Database } from './db.js'
import type { VectorStore } from './vector-store.js'
import type { EmbeddingClient } from './embeddings.js'

export class EmbeddingIndexer {
  private indexed = new Set<string>()

  constructor(
    private db: Database,
    private store: VectorStore,
    private client: EmbeddingClient
  ) {}

  async indexAll(): Promise<number> {
    // Pre-populate from DB on first call to avoid re-embedding after restart
    if (this.indexed.size === 0) {
      try {
        const existing = this.db.getRawDb()
          .prepare('SELECT session_id FROM session_embeddings')
          .all() as { session_id: string }[]
        for (const row of existing) this.indexed.add(row.session_id)
      } catch {
        // Table may not exist yet if vector store hasn't initialized
      }
    }

    const sessions = this.db.listSessions({ limit: 10000 })
    let count = 0

    for (const session of sessions) {
      if (this.indexed.has(session.id)) continue

      const text = this.getSessionText(session.id)
      if (!text) {
        this.indexed.add(session.id)
        continue
      }

      const embedding = await this.client.embed(text)
      if (!embedding) continue

      this.store.upsert(session.id, embedding, this.client.model)
      this.indexed.add(session.id)
      count++
    }

    return count
  }

  async indexOne(sessionId: string): Promise<boolean> {
    const text = this.getSessionText(sessionId)
    if (!text) return false

    const embedding = await this.client.embed(text)
    if (!embedding) return false

    this.store.upsert(sessionId, embedding, this.client.model)
    this.indexed.add(sessionId)
    return true
  }

  private getSessionText(sessionId: string): string | null {
    const rows = this.db.getFtsContent(sessionId)
    if (!rows || rows.length === 0) return null
    const text = rows.join('\n').slice(0, 2000)
    return text.length > 0 ? text : null
  }
}
