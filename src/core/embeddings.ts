import OpenAI from 'openai'

export interface EmbeddingClient {
  embed(text: string): Promise<Float32Array | null>
  dimension: number
  model: string
}

interface EmbeddingClientOptions {
  ollamaUrl?: string
  openaiApiKey?: string
}

export function createEmbeddingClient(opts: EmbeddingClientOptions): EmbeddingClient {
  const ollamaUrl = opts.ollamaUrl ?? 'http://localhost:11434'
  const openaiClient = opts.openaiApiKey ? new OpenAI({ apiKey: opts.openaiApiKey }) : null
  let ollamaDown = false

  return {
    dimension: 768,
    model: 'auto',

    async embed(text: string): Promise<Float32Array | null> {
      // Try Ollama first (skip if previously failed)
      if (!ollamaDown) {
        try {
          const res = await fetch(`${ollamaUrl}/api/embed`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ model: 'nomic-embed-text', input: text }),
            signal: AbortSignal.timeout(10000),
          })
          if (res.ok) {
            const data = await res.json() as { embeddings: number[][] }
            if (data.embeddings?.[0]) {
              return new Float32Array(data.embeddings[0])
            }
          } else {
            // Server error (503, 500, etc.) — mark as down
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
            dimensions: 768,
          })
          if (res.data[0]) {
            return new Float32Array(res.data[0].embedding)
          }
        } catch { /* OpenAI not available */ }
      }

      return null
    },
  }
}
