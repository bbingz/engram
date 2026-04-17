import { randomUUID } from 'node:crypto';
import { DEFAULT_IMPORTANCE } from '../core/db/insight-repo.js';
import type { Database } from '../core/db.js';
import type { EmbeddingClient } from '../core/embeddings.js';
import type { Logger } from '../core/logger.js';
import type { VectorStore } from '../core/vector-store.js';

export const saveInsightTool = {
  name: 'save_insight',
  description:
    'Save an important insight, decision, or lesson learned for future retrieval. ' +
    'Use this to preserve knowledge that should persist across sessions.',
  inputSchema: {
    type: 'object' as const,
    required: ['content'],
    properties: {
      content: {
        type: 'string',
        description: 'The insight or knowledge to save',
      },
      wing: {
        type: 'string',
        description: 'Project or domain name (optional)',
      },
      room: {
        type: 'string',
        description: 'Sub-area within the project (optional)',
      },
      importance: {
        type: 'number',
        description: 'Importance level 0-5 (default: 5)',
        minimum: 0,
        maximum: 5,
      },
      source_session_id: {
        type: 'string',
        description: 'Session ID that generated this insight (optional)',
      },
    },
    additionalProperties: false,
  },
};

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
function _deleteInsight(
  id: string,
  deps: { db?: Database; vecStore?: VectorStore | null },
): boolean {
  let deleted = false;
  if (deps.db) {
    deleted = deps.db.deleteInsightText(id) || deleted;
  }
  if (deps.vecStore) {
    deps.vecStore.deleteInsight(id);
    deleted = true;
  }
  return deleted;
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

  const id = randomUUID();
  const importance = params.importance ?? DEFAULT_IMPORTANCE;

  // Text-only fallback: save to insights table when no embedding support
  if (!deps.vecStore || !deps.embedder) {
    if (!deps.db) {
      throw new Error(
        'Insight storage requires either embedding support or a database connection.',
      );
    }
    // Text-only dedup check
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
