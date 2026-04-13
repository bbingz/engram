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
  log?: Logger;
}

export async function handleGetMemory(
  params: { query: string },
  deps: GetMemoryDeps = {},
): Promise<{ memories: MemoryInsight[]; message?: string }> {
  deps.log?.info('get_memory invoked', { query: params.query.slice(0, 100) });

  if (!deps.vecStore || !deps.embedder) {
    return {
      memories: [],
      message:
        'Memory features require embedding support. Configure an embedding provider in ~/.engram/settings.json. Use save_insight to add memories.',
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
