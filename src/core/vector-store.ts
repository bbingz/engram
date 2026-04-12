import type BetterSqlite3 from 'better-sqlite3';
import * as sqliteVec from 'sqlite-vec';

export interface VectorSearchResult {
  sessionId: string;
  distance: number;
}

export interface ChunkSearchResult {
  chunkId: string;
  sessionId: string;
  chunkIndex: number;
  text: string;
  distance: number;
}

export interface InsightSearchResult {
  id: string;
  content: string;
  wing: string | null;
  room: string | null;
  importance: number;
  distance: number;
}

export interface VectorStore {
  upsert(sessionId: string, embedding: Float32Array, model?: string): void;
  search(query: Float32Array, topK: number): VectorSearchResult[];
  delete(sessionId: string): void;
  count(): number;

  // Chunk operations
  upsertChunks(
    chunks: {
      chunkId: string;
      sessionId: string;
      chunkIndex: number;
      text: string;
    }[],
    embeddings: Float32Array[],
    model: string,
  ): void;
  searchChunks(query: Float32Array, topK: number): ChunkSearchResult[];
  deleteChunksBySession(sessionId: string): void;

  // Insight operations
  upsertInsight(
    id: string,
    content: string,
    embedding: Float32Array,
    model: string,
    opts?: {
      wing?: string;
      room?: string;
      sourceSessionId?: string;
      importance?: number;
    },
  ): void;
  searchInsights(query: Float32Array, topK: number): InsightSearchResult[];
  deleteInsight(id: string): void;
  countInsights(): number;

  // Model tracking
  activeModel(): string | null;
  dropAndRebuild(): void;
}

export class SqliteVecStore implements VectorStore {
  private stmts!: {
    deleteVec: BetterSqlite3.Statement;
    deleteEmb: BetterSqlite3.Statement;
    insertVec: BetterSqlite3.Statement;
    insertEmb: BetterSqlite3.Statement;
    search: BetterSqlite3.Statement;
    count: BetterSqlite3.Statement;
    // Chunk stmts
    deleteChunkVec: BetterSqlite3.Statement;
    deleteChunkMeta: BetterSqlite3.Statement;
    insertChunkVec: BetterSqlite3.Statement;
    insertChunkMeta: BetterSqlite3.Statement;
    searchChunks: BetterSqlite3.Statement;
    deleteChunksBySession: BetterSqlite3.Statement;
    deleteChunkVecBySession: BetterSqlite3.Statement;
    // Insight stmts
    insertInsight: BetterSqlite3.Statement;
    insertInsightVec: BetterSqlite3.Statement;
    deleteInsight: BetterSqlite3.Statement;
    deleteInsightVec: BetterSqlite3.Statement;
    searchInsights: BetterSqlite3.Statement;
    countInsights: BetterSqlite3.Statement;
  };
  private upsertTxn!: BetterSqlite3.Transaction<
    (sessionId: string, buf: Buffer, model: string) => void
  >;
  private upsertChunksTxn!: BetterSqlite3.Transaction<
    (
      chunks: {
        chunkId: string;
        sessionId: string;
        chunkIndex: number;
        text: string;
      }[],
      bufs: Buffer[],
      model: string,
    ) => void
  >;

  constructor(
    private db: BetterSqlite3.Database,
    private dimension = 768,
  ) {
    sqliteVec.load(db);
    this.migrate();
    this.prepareStatements();
  }

  private migrate(): void {
    // Check model + dimension — rebuild if either changed
    const metaExists = this.db
      .prepare(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='metadata'",
      )
      .get();

    let needsRebuild = false;
    if (metaExists) {
      const storedDim = this.db
        .prepare("SELECT value FROM metadata WHERE key = 'vec_dimension'")
        .pluck()
        .get() as string | undefined;
      const storedModel = this.db
        .prepare("SELECT value FROM metadata WHERE key = 'vec_model'")
        .pluck()
        .get() as string | undefined;
      if (storedDim && Number(storedDim) !== this.dimension) {
        needsRebuild = true;
      }
      // Model mismatch also triggers rebuild (tracked externally via setActiveModel)
      if (storedModel === '__pending_rebuild__') {
        needsRebuild = true;
      }
    }

    const vecExists = this.db
      .prepare(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='vec_sessions'",
      )
      .get();

    if (vecExists && needsRebuild) {
      this.db.exec(`
        DROP TABLE IF EXISTS vec_sessions;
        DROP TABLE IF EXISTS vec_chunks;
        DROP TABLE IF EXISTS vec_insights;
        DELETE FROM session_embeddings;
        DELETE FROM session_chunks;
      `);
    }

    this.db.exec(`
      CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT);
      CREATE TABLE IF NOT EXISTS session_embeddings (
        session_id TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE,
        model TEXT NOT NULL,
        created_at TEXT DEFAULT (datetime('now'))
      );
      CREATE VIRTUAL TABLE IF NOT EXISTS vec_sessions USING vec0(
        session_id TEXT PRIMARY KEY,
        embedding float[${this.dimension}]
      );

      -- Chunk tables
      CREATE TABLE IF NOT EXISTS session_chunks (
        chunk_id TEXT PRIMARY KEY,
        session_id TEXT NOT NULL,
        chunk_index INTEGER NOT NULL,
        text TEXT NOT NULL,
        model TEXT NOT NULL,
        created_at TEXT DEFAULT (datetime('now'))
      );
      CREATE INDEX IF NOT EXISTS idx_chunks_session ON session_chunks(session_id);
      CREATE VIRTUAL TABLE IF NOT EXISTS vec_chunks USING vec0(
        chunk_id TEXT PRIMARY KEY,
        embedding float[${this.dimension}]
      );

      -- Insight tables
      CREATE TABLE IF NOT EXISTS memory_insights (
        id TEXT PRIMARY KEY,
        content TEXT NOT NULL,
        wing TEXT,
        room TEXT,
        source_session_id TEXT,
        importance INTEGER DEFAULT 3,
        model TEXT NOT NULL DEFAULT 'unknown',
        created_at TEXT DEFAULT (datetime('now')),
        deleted_at TEXT
      );
      CREATE VIRTUAL TABLE IF NOT EXISTS vec_insights USING vec0(
        insight_id TEXT PRIMARY KEY,
        embedding float[${this.dimension}]
      );

      INSERT OR REPLACE INTO metadata (key, value) VALUES ('vec_dimension', '${this.dimension}');
    `);
  }

  private prepareStatements(): void {
    this.stmts = {
      // Session-level (legacy)
      deleteVec: this.db.prepare(
        'DELETE FROM vec_sessions WHERE session_id = ?',
      ),
      deleteEmb: this.db.prepare(
        'DELETE FROM session_embeddings WHERE session_id = ?',
      ),
      insertVec: this.db.prepare(
        'INSERT INTO vec_sessions (session_id, embedding) VALUES (?, ?)',
      ),
      insertEmb: this.db.prepare(
        'INSERT INTO session_embeddings (session_id, model) VALUES (?, ?)',
      ),
      search: this.db.prepare(`
        SELECT session_id, distance
        FROM vec_sessions
        WHERE embedding MATCH ? AND k = ?
        ORDER BY distance
      `),
      count: this.db.prepare('SELECT COUNT(*) as n FROM session_embeddings'),

      // Chunks
      deleteChunkVec: this.db.prepare(
        'DELETE FROM vec_chunks WHERE chunk_id = ?',
      ),
      deleteChunkMeta: this.db.prepare(
        'DELETE FROM session_chunks WHERE chunk_id = ?',
      ),
      insertChunkVec: this.db.prepare(
        'INSERT INTO vec_chunks (chunk_id, embedding) VALUES (?, ?)',
      ),
      insertChunkMeta: this.db.prepare(
        'INSERT INTO session_chunks (chunk_id, session_id, chunk_index, text, model) VALUES (?, ?, ?, ?, ?)',
      ),
      searchChunks: this.db.prepare(`
        SELECT vc.chunk_id, vc.distance, sc.session_id, sc.chunk_index, sc.text
        FROM vec_chunks vc
        JOIN session_chunks sc ON sc.chunk_id = vc.chunk_id
        WHERE vc.embedding MATCH ? AND k = ?
        ORDER BY vc.distance
      `),
      deleteChunksBySession: this.db.prepare(
        'DELETE FROM session_chunks WHERE session_id = ?',
      ),
      deleteChunkVecBySession: this.db.prepare(
        'DELETE FROM vec_chunks WHERE chunk_id IN (SELECT chunk_id FROM session_chunks WHERE session_id = ?)',
      ),

      // Insights
      insertInsight: this.db.prepare(
        'INSERT OR REPLACE INTO memory_insights (id, content, wing, room, source_session_id, importance, model) VALUES (?, ?, ?, ?, ?, ?, ?)',
      ),
      insertInsightVec: this.db.prepare(
        'INSERT OR REPLACE INTO vec_insights (insight_id, embedding) VALUES (?, ?)',
      ),
      deleteInsight: this.db.prepare(
        "UPDATE memory_insights SET deleted_at = datetime('now') WHERE id = ?",
      ),
      deleteInsightVec: this.db.prepare(
        'DELETE FROM vec_insights WHERE insight_id = ?',
      ),
      searchInsights: this.db.prepare(`
        SELECT vi.insight_id as id, vi.distance, mi.content, mi.wing, mi.room, mi.importance
        FROM vec_insights vi
        JOIN memory_insights mi ON mi.id = vi.insight_id
        WHERE vi.embedding MATCH ? AND k = ?
          AND mi.deleted_at IS NULL
        ORDER BY vi.distance
      `),
      countInsights: this.db.prepare(
        'SELECT COUNT(*) as n FROM memory_insights WHERE deleted_at IS NULL',
      ),
    };

    this.upsertTxn = this.db.transaction(
      (sessionId: string, buf: Buffer, model: string) => {
        this.stmts.deleteVec.run(sessionId);
        this.stmts.deleteEmb.run(sessionId);
        this.stmts.insertVec.run(sessionId, buf);
        this.stmts.insertEmb.run(sessionId, model);
      },
    );

    this.upsertChunksTxn = this.db.transaction(
      (
        chunks: {
          chunkId: string;
          sessionId: string;
          chunkIndex: number;
          text: string;
        }[],
        bufs: Buffer[],
        model: string,
      ) => {
        if (chunks.length === 0) return;
        // Delete existing chunks for this session
        const sid = chunks[0].sessionId;
        // Must delete vec entries before metadata (FK-like dependency via chunk_id)
        const existingChunkIds = this.db
          .prepare('SELECT chunk_id FROM session_chunks WHERE session_id = ?')
          .pluck()
          .all(sid) as string[];
        for (const cid of existingChunkIds) {
          this.stmts.deleteChunkVec.run(cid);
        }
        this.stmts.deleteChunksBySession.run(sid);

        // Insert new
        for (let i = 0; i < chunks.length; i++) {
          const c = chunks[i];
          const buf = bufs[i];
          this.stmts.insertChunkMeta.run(
            c.chunkId,
            c.sessionId,
            c.chunkIndex,
            c.text,
            model,
          );
          this.stmts.insertChunkVec.run(c.chunkId, buf);
        }
      },
    );
  }

  // --- Session-level (legacy) ---

  upsert(sessionId: string, embedding: Float32Array, model = 'unknown'): void {
    const buf = Buffer.from(
      embedding.buffer,
      embedding.byteOffset,
      embedding.byteLength,
    );
    this.upsertTxn(sessionId, buf, model);
  }

  search(query: Float32Array, topK: number): VectorSearchResult[] {
    const buf = Buffer.from(query.buffer, query.byteOffset, query.byteLength);
    const rows = this.stmts.search.all(buf, topK) as {
      session_id: string;
      distance: number;
    }[];
    return rows.map((r) => ({ sessionId: r.session_id, distance: r.distance }));
  }

  delete(sessionId: string): void {
    this.stmts.deleteVec.run(sessionId);
    this.stmts.deleteEmb.run(sessionId);
  }

  count(): number {
    const row = this.stmts.count.get() as { n: number };
    return row.n;
  }

  // --- Chunks ---

  upsertChunks(
    chunks: {
      chunkId: string;
      sessionId: string;
      chunkIndex: number;
      text: string;
    }[],
    embeddings: Float32Array[],
    model: string,
  ): void {
    const bufs = embeddings.map((e) =>
      Buffer.from(e.buffer, e.byteOffset, e.byteLength),
    );
    this.upsertChunksTxn(chunks, bufs, model);
  }

  searchChunks(query: Float32Array, topK: number): ChunkSearchResult[] {
    const buf = Buffer.from(query.buffer, query.byteOffset, query.byteLength);
    const rows = this.stmts.searchChunks.all(buf, topK) as {
      chunk_id: string;
      session_id: string;
      chunk_index: number;
      text: string;
      distance: number;
    }[];
    return rows.map((r) => ({
      chunkId: r.chunk_id,
      sessionId: r.session_id,
      chunkIndex: r.chunk_index,
      text: r.text,
      distance: r.distance,
    }));
  }

  deleteChunksBySession(sessionId: string): void {
    // Delete vec entries first
    const chunkIds = this.db
      .prepare('SELECT chunk_id FROM session_chunks WHERE session_id = ?')
      .pluck()
      .all(sessionId) as string[];
    for (const cid of chunkIds) {
      this.stmts.deleteChunkVec.run(cid);
    }
    this.stmts.deleteChunksBySession.run(sessionId);
  }

  // --- Insights ---

  upsertInsight(
    id: string,
    content: string,
    embedding: Float32Array,
    model: string,
    opts?: {
      wing?: string;
      room?: string;
      sourceSessionId?: string;
      importance?: number;
    },
  ): void {
    const buf = Buffer.from(
      embedding.buffer,
      embedding.byteOffset,
      embedding.byteLength,
    );
    this.stmts.insertInsight.run(
      id,
      content,
      opts?.wing ?? null,
      opts?.room ?? null,
      opts?.sourceSessionId ?? null,
      opts?.importance ?? 3,
      model,
    );
    this.stmts.insertInsightVec.run(id, buf);
  }

  searchInsights(query: Float32Array, topK: number): InsightSearchResult[] {
    const buf = Buffer.from(query.buffer, query.byteOffset, query.byteLength);
    const rows = this.stmts.searchInsights.all(buf, topK) as {
      id: string;
      content: string;
      wing: string | null;
      room: string | null;
      importance: number;
      distance: number;
    }[];
    return rows;
  }

  deleteInsight(id: string): void {
    this.stmts.deleteInsight.run(id);
    this.stmts.deleteInsightVec.run(id);
  }

  countInsights(): number {
    const row = this.stmts.countInsights.get() as { n: number };
    return row.n;
  }

  // --- Model tracking ---

  activeModel(): string | null {
    const row = this.db
      .prepare("SELECT value FROM metadata WHERE key = 'vec_model'")
      .pluck()
      .get() as string | undefined;
    return row ?? null;
  }

  setActiveModel(model: string): void {
    this.db
      .prepare(
        "INSERT OR REPLACE INTO metadata (key, value) VALUES ('vec_model', ?)",
      )
      .run(model);
  }

  dropAndRebuild(): void {
    this.db.exec(`
      DROP TABLE IF EXISTS vec_sessions;
      DROP TABLE IF EXISTS vec_chunks;
      DROP TABLE IF EXISTS vec_insights;
      DELETE FROM session_embeddings;
      DELETE FROM session_chunks;
      DELETE FROM memory_insights;
    `);
    this.migrate();
    this.prepareStatements();
  }
}
