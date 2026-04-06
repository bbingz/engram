import OpenAI from 'openai'
import type { AiAuditWriter } from './ai-audit.js'

export interface EmbeddingClient {
  embed(text: string): Promise<Float32Array | null>
  dimension: number
  model: string
}

export interface EmbeddingClientOptions {
  ollamaUrl?: string
  ollamaModel?: string
  openaiApiKey?: string
  dimension?: number
  audit?: AiAuditWriter
}

export function createEmbeddingClient(opts: EmbeddingClientOptions): EmbeddingClient {
  const ollamaUrl = (opts.ollamaUrl ?? 'http://localhost:11434').replace(/\/+$/, '')
  const ollamaModel = opts.ollamaModel ?? 'nomic-embed-text'
  const dimension = opts.dimension ?? 768
  const openaiClient = opts.openaiApiKey ? new OpenAI({ apiKey: opts.openaiApiKey }) : null
  const audit = opts.audit
  let ollamaDown = false

  let lastUsedModel = 'unknown'

  return {
    dimension,
    get model() { return lastUsedModel },

    async embed(text: string): Promise<Float32Array | null> {
      // Try Ollama first (skip if previously failed)
      if (!ollamaDown) {
        const start = Date.now()
        try {
          const res = await fetch(`${ollamaUrl}/api/embed`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ model: ollamaModel, input: text }),
            signal: AbortSignal.timeout(30000),
          })
          if (res.ok) {
            const data = await res.json() as { embeddings: number[][]; prompt_eval_count?: number }
            if (data.embeddings?.[0]) {
              lastUsedModel = ollamaModel
              const raw = data.embeddings[0]
              const promptTokens = data.prompt_eval_count ?? undefined
              audit?.record({
                caller: 'embedding', operation: 'embed',
                method: 'POST', url: `${ollamaUrl}/api/embed`,
                statusCode: 200, model: ollamaModel, provider: 'ollama',
                promptTokens, durationMs: Date.now() - start,
                meta: { dimension },
              })
              // Truncate or use as-is to match configured dimension
              return new Float32Array(raw.length > dimension ? raw.slice(0, dimension) : raw)
            }
          } else {
            audit?.record({
              caller: 'embedding', operation: 'embed',
              method: 'POST', url: `${ollamaUrl}/api/embed`,
              statusCode: res.status, model: ollamaModel, provider: 'ollama',
              durationMs: Date.now() - start,
              error: `HTTP ${res.status}`,
              meta: { dimension },
            })
            ollamaDown = true
            setTimeout(() => { ollamaDown = false }, 60_000)
          }
        } catch (err) {
          audit?.record({
            caller: 'embedding', operation: 'embed',
            method: 'POST', url: `${ollamaUrl}/api/embed`,
            model: ollamaModel, provider: 'ollama',
            durationMs: Date.now() - start,
            error: err instanceof Error ? err.message : String(err),
            meta: { dimension },
          })
          ollamaDown = true
          setTimeout(() => { ollamaDown = false }, 60_000)
        }
      }

      // Fallback to OpenAI
      if (openaiClient) {
        const start = Date.now()
        try {
          const res = await openaiClient.embeddings.create({
            model: 'text-embedding-3-small',
            input: text,
            dimensions: dimension,
          })
          if (res.data[0]) {
            lastUsedModel = 'text-embedding-3-small'
            const promptTokens = res.usage?.prompt_tokens ?? undefined
            audit?.record({
              caller: 'embedding', operation: 'embed',
              model: 'text-embedding-3-small', provider: 'openai',
              promptTokens, durationMs: Date.now() - start,
              meta: { dimension },
            })
            return new Float32Array(res.data[0].embedding)
          }
        } catch (err) {
          audit?.record({
            caller: 'embedding', operation: 'embed',
            model: 'text-embedding-3-small', provider: 'openai',
            durationMs: Date.now() - start,
            error: err instanceof Error ? err.message : String(err),
            meta: { dimension },
          })
        }
      }

      return null
    },
  }
}
