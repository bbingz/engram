import type { Database } from '../core/db.js';
import type { EmbeddingClient } from '../core/embeddings.js';
import type { Logger } from '../core/logger.js';
import type { InsightSearchResult, VectorStore } from '../core/vector-store.js';

export const getMemoryTool = {
  name: 'get_memory',
  description:
    'Retrieve curated insights and memories from past sessions. Use save_insight to add new memories.',
  inputSchema: {
    type: 'object' as const,
    required: ['query'],
    properties: {
      query: {
        type: 'string',
        description: 'What to remember (e.g. "user\'s coding preferences")',
      },
    },
    additionalProperties: false,
  },
};

interface MemoryInsight {
  id: string;
  content: string;
  wing: string | null;
  room: string | null;
  importance: number;
  distance: number;
}

interface GetMemoryDeps {
  vecStore?: VectorStore | null;
  embedder?: EmbeddingClient | null;
  db?: Database;
  log?: Logger;
}

export async function handleGetMemory(
  params: { query: string },
  deps: GetMemoryDeps = {},
): Promise<{ memories: MemoryInsight[]; message?: string; warning?: string }> {
  deps.log?.info('get_memory invoked', { query: params.query.slice(0, 100) });

  if (!deps.vecStore || !deps.embedder) {
    // Fall back to FTS keyword search on text-only insights
    if (deps.db) {
      try {
        const textInsights = deps.db.searchInsightsFts(params.query, 10);
        if (textInsights.length > 0) {
          return {
            memories: textInsights.map((r) => ({
              id: r.id,
              content: r.content,
              wing: r.wing,
              room: r.room,
              importance: r.importance,
              distance: 0,
            })),
            warning:
              'No embedding provider — showing keyword-matched insights only.',
          };
        }
      } catch {
        /* FTS query failed (e.g. bad trigram), fall through */
      }
      // No FTS hits — try listing recent insights
      const recent = deps.db.listInsightsByWing(undefined, 10);
      if (recent.length > 0) {
        return {
          memories: recent.map((r) => ({
            id: r.id,
            content: r.content,
            wing: r.wing,
            room: r.room,
            importance: r.importance,
            distance: 0,
          })),
          warning: 'No embedding provider — showing recent insights only.',
        };
      }
    }
    return {
      memories: [],
      message:
        'No memories found. Use save_insight to add knowledge that persists across sessions.',
      warning: deps.db
        ? undefined
        : 'No embedding provider configured. Configure one in ~/.engram/settings.json.',
    };
  }

  const embedding = await deps.embedder.embed(params.query);
  if (!embedding) {
    return {
      memories: [],
      message:
        'Failed to generate query embedding. Check embedding provider configuration.',
    };
  }

  const results = deps.vecStore.searchInsights(embedding, 10);
  if (results.length === 0) {
    return {
      memories: [],
      message:
        'No memories found. Use save_insight to add knowledge that persists across sessions.',
    };
  }

  return {
    memories: results.map((r: InsightSearchResult) => ({
      id: r.id,
      content: r.content,
      wing: r.wing,
      room: r.room,
      importance: r.importance,
      distance: r.distance,
    })),
  };
}
