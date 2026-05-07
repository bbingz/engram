import OpenAI from 'openai';
import type { AiAuditWriter } from './ai-audit.js';

export interface EmbeddingAuditContext {
  sessionId?: string;
  textKind?: 'session' | 'chunk' | 'insight' | 'query';
  chunkId?: string;
  chunkIndex?: number;
}

export interface EmbeddingClient {
  embed(
    text: string,
    context?: EmbeddingAuditContext,
  ): Promise<Float32Array | null>;
  dimension: number;
  model: string;
}

type EmbeddingProvider = 'ollama' | 'openai' | 'transformers';

interface EmbeddingClientOptions {
  provider?: EmbeddingProvider;
  ollamaUrl?: string;
  ollamaModel?: string;
  openaiApiKey?: string;
  dimension?: number;
  audit?: AiAuditWriter;
}

function contextMeta(context?: EmbeddingAuditContext): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  if (context?.textKind !== undefined) out.textKind = context.textKind;
  if (context?.chunkId !== undefined) out.chunkId = context.chunkId;
  if (context?.chunkIndex !== undefined) out.chunkIndex = context.chunkIndex;
  return out;
}

/**
 * L2-normalize a vector in-place. Required after dimension truncation
 * to preserve cosine similarity geometry.
 */
function l2Normalize(arr: Float32Array): void {
  const norm = Math.sqrt(arr.reduce((sum, v) => sum + v * v, 0));
  if (norm > 0) for (let i = 0; i < arr.length; i++) arr[i] /= norm;
}

/**
 * Lazy-load Transformers.js pipeline. Returns null if package not installed.
 */
// biome-ignore lint/suspicious/noExplicitAny: dynamic import of optional @huggingface/transformers pipeline
let transformersPipeline: any = null;
// biome-ignore lint/suspicious/noExplicitAny: dynamic import of optional @huggingface/transformers pipeline
async function getTransformersPipeline(): Promise<any> {
  if (transformersPipeline) return transformersPipeline;
  try {
    const { pipeline, env } = await import('@huggingface/transformers');
    env.allowRemoteModels = true; // Allow first-time model download
    transformersPipeline = await pipeline(
      'feature-extraction',
      'Xenova/all-MiniLM-L6-v2',
      { dtype: 'fp32' },
    );
    return transformersPipeline;
  } catch {
    return null;
  }
}

export function createEmbeddingClient(
  opts: EmbeddingClientOptions,
): EmbeddingClient {
  const provider = opts.provider;
  const ollamaUrl = (opts.ollamaUrl ?? 'http://localhost:11434').replace(
    /\/+$/,
    '',
  );
  const ollamaModel = opts.ollamaModel ?? 'nomic-embed-text';
  const dimension = opts.dimension ?? 768;
  const openaiClient = opts.openaiApiKey
    ? new OpenAI({ apiKey: opts.openaiApiKey })
    : null;
  const audit = opts.audit;
  let ollamaDown = false;

  let lastUsedModel = 'unknown';

  async function embedWithTransformers(
    text: string,
    context?: EmbeddingAuditContext,
  ): Promise<Float32Array | null> {
    const start = Date.now();
    try {
      const pipe = await getTransformersPipeline();
      if (!pipe) return null;
      const output = await pipe(text, { pooling: 'mean', normalize: true });
      const data = output.data as Float32Array;
      lastUsedModel = 'all-MiniLM-L6-v2';
      audit?.record({
        caller: 'embedding',
        operation: 'embed',
        model: 'all-MiniLM-L6-v2',
        provider: 'transformers',
        durationMs: Date.now() - start,
        sessionId: context?.sessionId,
        meta: { dimension: data.length, ...contextMeta(context) },
      });
      return data;
    } catch (err) {
      audit?.record({
        caller: 'embedding',
        operation: 'embed',
        model: 'all-MiniLM-L6-v2',
        provider: 'transformers',
        durationMs: Date.now() - start,
        error: err instanceof Error ? err.message : String(err),
        sessionId: context?.sessionId,
        meta: contextMeta(context),
      });
      return null;
    }
  }

  async function embedWithOllama(
    text: string,
    context?: EmbeddingAuditContext,
  ): Promise<Float32Array | null> {
    if (ollamaDown) return null;
    const start = Date.now();
    try {
      const res = await fetch(`${ollamaUrl}/api/embed`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ model: ollamaModel, input: text }),
        signal: AbortSignal.timeout(30000),
      });
      if (res.ok) {
        const data = (await res.json()) as {
          embeddings: number[][];
          prompt_eval_count?: number;
        };
        if (data.embeddings?.[0]) {
          lastUsedModel = ollamaModel;
          const raw = data.embeddings[0];
          const promptTokens = data.prompt_eval_count ?? undefined;
          audit?.record({
            caller: 'embedding',
            operation: 'embed',
            method: 'POST',
            url: `${ollamaUrl}/api/embed`,
            statusCode: 200,
            model: ollamaModel,
            provider: 'ollama',
            promptTokens,
            durationMs: Date.now() - start,
            sessionId: context?.sessionId,
            meta: { dimension, ...contextMeta(context) },
          });
          // Truncate and L2-normalize to match configured dimension
          const vec = raw.length > dimension ? raw.slice(0, dimension) : raw;
          const arr = new Float32Array(vec);
          if (raw.length > dimension) {
            l2Normalize(arr);
          }
          return arr;
        }
      } else {
        audit?.record({
          caller: 'embedding',
          operation: 'embed',
          method: 'POST',
          url: `${ollamaUrl}/api/embed`,
          statusCode: res.status,
          model: ollamaModel,
          provider: 'ollama',
          durationMs: Date.now() - start,
          error: `HTTP ${res.status}`,
          sessionId: context?.sessionId,
          meta: { dimension, ...contextMeta(context) },
        });
        ollamaDown = true;
        setTimeout(() => {
          ollamaDown = false;
        }, 60_000);
      }
    } catch (err) {
      audit?.record({
        caller: 'embedding',
        operation: 'embed',
        method: 'POST',
        url: `${ollamaUrl}/api/embed`,
        model: ollamaModel,
        provider: 'ollama',
        durationMs: Date.now() - start,
        error: err instanceof Error ? err.message : String(err),
        sessionId: context?.sessionId,
        meta: { dimension, ...contextMeta(context) },
      });
      ollamaDown = true;
      setTimeout(() => {
        ollamaDown = false;
      }, 60_000);
    }
    return null;
  }

  async function embedWithOpenAI(
    text: string,
    context?: EmbeddingAuditContext,
  ): Promise<Float32Array | null> {
    if (!openaiClient) return null;
    const start = Date.now();
    try {
      const res = await openaiClient.embeddings.create({
        model: 'text-embedding-3-small',
        input: text,
        dimensions: dimension,
      });
      if (res.data[0]) {
        lastUsedModel = 'text-embedding-3-small';
        const promptTokens = res.usage?.prompt_tokens ?? undefined;
        audit?.record({
          caller: 'embedding',
          operation: 'embed',
          model: 'text-embedding-3-small',
          provider: 'openai',
          promptTokens,
          durationMs: Date.now() - start,
          sessionId: context?.sessionId,
          meta: { dimension, ...contextMeta(context) },
        });
        return new Float32Array(res.data[0].embedding);
      }
    } catch (err) {
      audit?.record({
        caller: 'embedding',
        operation: 'embed',
        model: 'text-embedding-3-small',
        provider: 'openai',
        durationMs: Date.now() - start,
        error: err instanceof Error ? err.message : String(err),
        sessionId: context?.sessionId,
        meta: { dimension, ...contextMeta(context) },
      });
    }
    return null;
  }

  return {
    dimension,
    get model() {
      return lastUsedModel;
    },

    async embed(
      text: string,
      context?: EmbeddingAuditContext,
    ): Promise<Float32Array | null> {
      // Explicit provider selection — no auto fallback chain to avoid
      // mixing vectors from different models in the same vector space
      if (provider === 'transformers') {
        return embedWithTransformers(text, context);
      }
      if (provider === 'openai') {
        return embedWithOpenAI(text, context);
      }
      // Default: Ollama only — no cross-model fallback to avoid
      // mixing incompatible embedding spaces in the same vector index
      return embedWithOllama(text, context);
    },
  };
}
