import type { VikingBridge, VikingMemory } from '../core/viking-bridge.js'

export const getMemoryTool = {
  name: 'get_memory',
  description: 'Retrieve memories extracted from past sessions. Requires OpenViking.',
  inputSchema: {
    type: 'object' as const,
    required: ['query'],
    properties: {
      query: { type: 'string', description: 'What to remember (e.g. "user\'s coding preferences")' },
    },
    additionalProperties: false,
  },
}

export interface GetMemoryDeps {
  viking?: VikingBridge | null
}

export async function handleGetMemory(
  params: { query: string },
  deps: GetMemoryDeps = {}
): Promise<{ memories: VikingMemory[]; message?: string }> {
  if (!deps.viking || !await deps.viking.checkAvailable()) {
    return {
      memories: [],
      message: 'Memory features require OpenViking. See docs for setup: configure viking.url and viking.apiKey in ~/.engram/settings.json',
    }
  }
  const memories = await deps.viking.findMemories(params.query)
  return { memories }
}
