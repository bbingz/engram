import { describe, it, expect } from 'vitest'
import { createEmbeddingClient, type EmbeddingClient } from '../../src/core/embeddings.js'

describe('EmbeddingClient', () => {
  it('returns null when no provider is available', async () => {
    const client = createEmbeddingClient({ ollamaUrl: 'http://localhost:99999', openaiApiKey: undefined })
    const result = await client.embed('test text')
    expect(result).toBeNull()
  })

  it('returns Float32Array of correct dimension when mocked', async () => {
    const mockClient: EmbeddingClient = {
      embed: async () => new Float32Array(768).fill(0.1),
      dimension: 768,
      model: 'mock',
    }
    const result = await mockClient.embed('hello world')
    expect(result).toBeInstanceOf(Float32Array)
    expect(result!.length).toBe(768)
  })
})
