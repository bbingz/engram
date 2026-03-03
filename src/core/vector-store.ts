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
  private stmts!: {
    deleteVec: BetterSqlite3.Statement
    deleteEmb: BetterSqlite3.Statement
    insertVec: BetterSqlite3.Statement
    insertEmb: BetterSqlite3.Statement
    search: BetterSqlite3.Statement
    count: BetterSqlite3.Statement
  }
  private upsertTxn!: BetterSqlite3.Transaction<(sessionId: string, buf: Buffer, model: string) => void>

  constructor(private db: BetterSqlite3.Database) {
    sqliteVec.load(db)
    this.migrate()
    this.prepareStatements()
  }

  private migrate(): void {
    this.db.exec(`
      CREATE TABLE IF NOT EXISTS session_embeddings (
        session_id TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE,
        model TEXT NOT NULL,
        created_at TEXT DEFAULT (datetime('now'))
      );
      CREATE VIRTUAL TABLE IF NOT EXISTS vec_sessions USING vec0(
        session_id TEXT PRIMARY KEY,
        embedding float[768]
      );
    `)
  }

  private prepareStatements(): void {
    this.stmts = {
      deleteVec: this.db.prepare('DELETE FROM vec_sessions WHERE session_id = ?'),
      deleteEmb: this.db.prepare('DELETE FROM session_embeddings WHERE session_id = ?'),
      insertVec: this.db.prepare('INSERT INTO vec_sessions (session_id, embedding) VALUES (?, ?)'),
      insertEmb: this.db.prepare('INSERT INTO session_embeddings (session_id, model) VALUES (?, ?)'),
      search: this.db.prepare(`
        SELECT session_id, distance
        FROM vec_sessions
        WHERE embedding MATCH ? AND k = ?
        ORDER BY distance
      `),
      count: this.db.prepare('SELECT COUNT(*) as n FROM session_embeddings'),
    }
    this.upsertTxn = this.db.transaction((sessionId: string, buf: Buffer, model: string) => {
      this.stmts.deleteVec.run(sessionId)
      this.stmts.deleteEmb.run(sessionId)
      this.stmts.insertVec.run(sessionId, buf)
      this.stmts.insertEmb.run(sessionId, model)
    })
  }

  upsert(sessionId: string, embedding: Float32Array, model = 'unknown'): void {
    const buf = Buffer.from(embedding.buffer, embedding.byteOffset, embedding.byteLength)
    this.upsertTxn(sessionId, buf, model)
  }

  search(query: Float32Array, topK: number): VectorSearchResult[] {
    const buf = Buffer.from(query.buffer, query.byteOffset, query.byteLength)
    const rows = this.stmts.search.all(buf, topK) as { session_id: string; distance: number }[]
    return rows.map(r => ({ sessionId: r.session_id, distance: r.distance }))
  }

  delete(sessionId: string): void {
    this.stmts.deleteVec.run(sessionId)
    this.stmts.deleteEmb.run(sessionId)
  }

  count(): number {
    const row = this.stmts.count.get() as { n: number }
    return row.n
  }
}
