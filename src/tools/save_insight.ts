import { randomUUID } from 'node:crypto';
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
        description: 'Importance level 0-5 (default: 3)',
        minimum: 0,
        maximum: 5,
      },
    },
    additionalProperties: false,
  },
};

interface SaveInsightDeps {
  vecStore?: VectorStore | null;
  embedder?: EmbeddingClient | null;
  log?: Logger;
}

interface SaveInsightResult {
  id: string;
  content: string;
  wing?: string;
  room?: string;
  importance: number;
  duplicateWarning?: string;
}

const DEDUP_THRESHOLD = 0.85;

export async function handleSaveInsight(
  params: {
    content: string;
    wing?: string;
    room?: string;
    importance?: number;
  },
  deps: SaveInsightDeps = {},
): Promise<SaveInsightResult> {
  deps.log?.info('save_insight invoked', {
    contentLength: params.content.length,
    wing: params.wing,
  });

  if (!deps.vecStore || !deps.embedder) {
    throw new Error(
      'Insight storage requires embedding support. Ensure an embedding provider is configured.',
    );
  }

  const embedding = await deps.embedder.embed(params.content);
  if (!embedding) {
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
  const importance = params.importance ?? 3;

  deps.vecStore.upsertInsight(
    id,
    params.content,
    embedding,
    deps.embedder.model,
    {
      wing: params.wing,
      room: params.room,
      importance,
    },
  );

  return {
    id,
    content: params.content,
    wing: params.wing,
    room: params.room,
    importance,
    duplicateWarning,
  };
}
