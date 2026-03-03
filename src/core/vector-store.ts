import type BetterSqlite3 from 'better-sqlite3'
import * as sqliteVec from 'sqlite-vec'

export interface VectorSearchResult {
  sessionId: string
  distance: number
}

export interface VectorStore {
  upsert(sessionId: string, embedding: Float32Array, model?: string): void
  search(query: Float32Array, topK: number): VectorSearchResult[]
  delete(sessionId: string): void
  count(): number
}

export class SqliteVecStore implements VectorStore {
  constructor(private db: BetterSqlite3.Database) {
    sqliteVec.load(db)
    this.migrate()
  }

  private migrate(): void {
    this.db.exec(`
      CREATE TABLE IF NOT EXISTS session_embeddings (
        session_id TEXT PRIMARY KEY,
        model TEXT NOT NULL,
        created_at TEXT DEFAULT (datetime('now'))
      );
      CREATE VIRTUAL TABLE IF NOT EXISTS vec_sessions USING vec0(
        session_id TEXT PRIMARY KEY,
        embedding float[768]
      );
    `)
  }

  upsert(sessionId: string, embedding: Float32Array, model = 'unknown'): void {
    const buf = Buffer.from(embedding.buffer, embedding.byteOffset, embedding.byteLength)
    const transaction = this.db.transaction(() => {
      this.db.prepare('DELETE FROM vec_sessions WHERE session_id = ?').run(sessionId)
      this.db.prepare('DELETE FROM session_embeddings WHERE session_id = ?').run(sessionId)
      this.db.prepare('INSERT INTO vec_sessions (session_id, embedding) VALUES (?, ?)').run(sessionId, buf)
      this.db.prepare('INSERT INTO session_embeddings (session_id, model) VALUES (?, ?)').run(sessionId, model)
    })
    transaction()
  }

  search(query: Float32Array, topK: number): VectorSearchResult[] {
    const buf = Buffer.from(query.buffer, query.byteOffset, query.byteLength)
    const rows = this.db.prepare(`
      SELECT session_id, distance
      FROM vec_sessions
      WHERE embedding MATCH ? AND k = ?
      ORDER BY distance
    `).all(buf, topK) as { session_id: string; distance: number }[]
    return rows.map(r => ({ sessionId: r.session_id, distance: r.distance }))
  }

  delete(sessionId: string): void {
    this.db.prepare('DELETE FROM vec_sessions WHERE session_id = ?').run(sessionId)
    this.db.prepare('DELETE FROM session_embeddings WHERE session_id = ?').run(sessionId)
  }

  count(): number {
    const row = this.db.prepare('SELECT COUNT(*) as n FROM session_embeddings').get() as { n: number }
    return row.n
  }
}
