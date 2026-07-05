import { randomUUID } from 'node:crypto';
import { DEFAULT_IMPORTANCE } from '../core/db/insight-repo.js';
import type { Database } from '../core/db.js';
import type { EmbeddingClient } from '../core/embeddings.js';
import type { Logger } from '../core/logger.js';
import type { VectorStore } from '../core/vector-store.js';

interface SaveInsightDeps {
  vecStore?: VectorStore | null;
  embedder?: EmbeddingClient | null;
  db?: Database;
  log?: Logger;
}

interface SaveInsightResult {
  id: string;
  content: string;
  wing?: string;
  room?: string;
  importance: number;
  duplicateWarning?: string;
  warning?: string;
}

const DEDUP_THRESHOLD = 0.85;

/**
 * Delete an insight from both text (insights+FTS) and vector (memory_insights+vec_insights) stores.
 * Callers don't need to remember to delete from both — this is the single entry point.
 */
function deleteInsight(
  id: string,
  deps: { db?: Database; vecStore?: VectorStore | null },
): boolean {
  let deleted = false;
  if (deps.db) {
    deleted = deps.db.deleteInsightText(id) || deleted;
  }
  if (deps.vecStore) {
    // VectorStore.deleteInsight returns void, so we can't learn whether a row
    // was removed there. Only treat the overall delete as successful when the
    // text store actually removed a row (the text store is the authoritative
    // index — every embedded insight also has a text row). Previously this
    // returned true unconditionally whenever a vecStore existed, so deleting a
    // nonexistent id falsely reported success.
    deps.vecStore.deleteInsight(id);
  }
  return deleted;
}

export function handleDeleteInsight(
  params: { id: string; dry_run?: boolean },
  deps: SaveInsightDeps = {},
): { id: string; deleted: boolean; dry_run?: boolean } {
  const id = String(params.id ?? '').trim();
  if (!id) {
    throw new Error('id is required.');
  }
  if (params.dry_run) {
    return { id, deleted: false, dry_run: true };
  }
  return { id, deleted: deleteInsight(id, deps) };
}

export async function handleSaveInsight(
  params: {
    content: string;
    wing?: string;
    room?: string;
    importance?: number;
    source_session_id?: string;
  },
  deps: SaveInsightDeps = {},
): Promise<SaveInsightResult> {
  deps.log?.info('save_insight invoked', {
    contentLength: params.content.length,
    wing: params.wing,
  });

  // Input validation
  const trimmedContent = params.content.trim();
  if (!trimmedContent) {
    throw new Error('Content cannot be empty.');
  }
  if (trimmedContent.length < 10) {
    throw new Error(
      `Content too short (${trimmedContent.length} chars, minimum 10).`,
    );
  }
  if (trimmedContent.length > 50_000) {
    throw new Error(
      `Content too long (${trimmedContent.length} chars, maximum 50,000).`,
    );
  }
  params.content = trimmedContent;

  if (params.wing) params.wing = params.wing.trim().slice(0, 200);
  if (params.room) params.room = params.room.trim().slice(0, 200);

  // Validate source_session_id shape. Session ids across sources are bounded
  // identifiers (UUIDs, slugs, file stems) — reject anything with control
  // chars, whitespace, or absurd length so a malformed/injected value can't be
  // persisted into the insight stores. Existence isn't checked: insights may
  // outlive their source session and `db` isn't always present here.
  if (params.source_session_id !== undefined) {
    const sid = params.source_session_id.trim();
    if (!sid) {
      params.source_session_id = undefined;
    } else if (sid.length > 256 || !/^[\w.@:+/-]+$/.test(sid)) {
      throw new Error(
        'source_session_id has an invalid format (expected a bounded session identifier).',
      );
    } else {
      params.source_session_id = sid;
    }
  }

  const importance = params.importance ?? DEFAULT_IMPORTANCE;

  // Text-only fallback: save to insights table when no embedding support
  if (!deps.vecStore || !deps.embedder) {
    if (!deps.db) {
      throw new Error(
        'Insight storage requires either embedding support or a database connection.',
      );
    }
    // Text-only dedup check — generate the UUID only after we know we will
    // actually insert. Generating it upfront wasted cryptographic work on the
    // common duplicate path.
    const existing = deps.db.findDuplicateInsight(params.content, params.wing);
    if (existing) {
      return {
        id: existing.id,
        content: existing.content,
        wing: existing.wing ?? undefined,
        room: existing.room ?? undefined,
        importance: existing.importance,
        duplicateWarning: `Duplicate insight already exists (id: ${existing.id}), skipping save.`,
      };
    }

    const id = randomUUID();
    deps.db.saveInsightText(
      id,
      params.content,
      params.wing,
      params.room,
      importance,
      params.source_session_id,
    );
    return {
      id,
      content: params.content,
      wing: params.wing,
      room: params.room,
      importance,
      warning:
        'Saved without embedding — keyword search only until an embedding provider is configured.',
    };
  }

  const embedding = await deps.embedder.embed(params.content);
  if (!embedding) {
    // Embedding failed — fall back to text-only if DB available
    if (deps.db) {
      // Text-only dedup check
      const existing = deps.db.findDuplicateInsight(
        params.content,
        params.wing,
      );
      if (existing) {
        return {
          id: existing.id,
          content: existing.content,
          wing: existing.wing ?? undefined,
          room: existing.room ?? undefined,
          importance: existing.importance,
          duplicateWarning: `Duplicate insight already exists (id: ${existing.id}), skipping save.`,
        };
      }

      const id = randomUUID();
      deps.db.saveInsightText(
        id,
        params.content,
        params.wing,
        params.room,
        importance,
        params.source_session_id,
      );
      return {
        id,
        content: params.content,
        wing: params.wing,
        room: params.room,
        importance,
        warning: 'Embedding generation failed — saved as text-only.',
      };
    }
    throw new Error('Failed to generate embedding for insight content.');
  }

  // Semantic dedup check
  let duplicateWarning: string | undefined;
  const existing = deps.vecStore.searchInsights(embedding, 1);
  if (existing.length > 0) {
    // sqlite-vec returns L2 distance; convert to approximate cosine similarity
    // For normalized vectors: cosine_similarity ≈ 1 - (distance² / 2)
    const dist = existing[0].distance;
    const cosineSim = 1 - (dist * dist) / 2;
    if (cosineSim > DEDUP_THRESHOLD) {
      duplicateWarning = `Similar insight already exists (similarity: ${(cosineSim * 100).toFixed(0)}%): "${existing[0].content.slice(0, 100)}..."`;
    }
  }

  const id = randomUUID();
  deps.vecStore.upsertInsight(
    id,
    params.content,
    embedding,
    deps.embedder.model,
    {
      wing: params.wing,
      room: params.room,
      importance,
      sourceSessionId: params.source_session_id,
    },
  );

  // Also persist to text store for FTS search
  if (deps.db) {
    deps.db.saveInsightText(
      id,
      params.content,
      params.wing,
      params.room,
      importance,
      params.source_session_id,
    );
    deps.db.markInsightEmbedded(id);
  }

  return {
    id,
    content: params.content,
    wing: params.wing,
    room: params.room,
    importance,
    duplicateWarning,
  };
}
