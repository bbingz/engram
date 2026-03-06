import OpenAI from 'openai'

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
}

export function createEmbeddingClient(opts: EmbeddingClientOptions): EmbeddingClient {
  const ollamaUrl = (opts.ollamaUrl ?? 'http://localhost:11434').replace(/\/+$/, '')
  const ollamaModel = opts.ollamaModel ?? 'nomic-embed-text'
  const dimension = opts.dimension ?? 768
  const openaiClient = opts.openaiApiKey ? new OpenAI({ apiKey: opts.openaiApiKey }) : null
  let ollamaDown = false

  let lastUsedModel = 'unknown'

  return {
    dimension,
    get model() { return lastUsedModel },

    async embed(text: string): Promise<Float32Array | null> {
      // Try Ollama first (skip if previously failed)
      if (!ollamaDown) {
        try {
          const res = await fetch(`${ollamaUrl}/api/embed`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ model: ollamaModel, input: text }),
            signal: AbortSignal.timeout(30000),
          })
          if (res.ok) {
            const data = await res.json() as { embeddings: number[][] }
            if (data.embeddings?.[0]) {
              lastUsedModel = ollamaModel
              const raw = data.embeddings[0]
              // Truncate or use as-is to match configured dimension
              return new Float32Array(raw.length > dimension ? raw.slice(0, dimension) : raw)
            }
          } else {
            ollamaDown = true
            setTimeout(() => { ollamaDown = false }, 60_000)
          }
        } catch {
          ollamaDown = true
          setTimeout(() => { ollamaDown = false }, 60_000)
        }
      }

      // Fallback to OpenAI
      if (openaiClient) {
        try {
          const res = await openaiClient.embeddings.create({
            model: 'text-embedding-3-small',
            input: text,
            dimensions: dimension,
          })
          if (res.data[0]) {
            lastUsedModel = 'text-embedding-3-small'
            return new Float32Array(res.data[0].embedding)
          }
        } catch { /* OpenAI not available */ }
      }

      return null
    },
  }
}
