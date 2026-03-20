export interface ModelPrice {
  input: number     // USD per 1M input tokens
  output: number    // USD per 1M output tokens
  cacheRead: number // USD per 1M cache-read tokens
  cacheWrite: number // USD per 1M cache-creation tokens
}

export const MODEL_PRICING: Record<string, ModelPrice> = {
  'claude-opus-4-6':     { input: 15,   output: 75,  cacheRead: 1.5,   cacheWrite: 18.75 },
  'claude-sonnet-4-6':   { input: 3,    output: 15,  cacheRead: 0.3,   cacheWrite: 3.75 },
  'claude-sonnet-4-5':   { input: 3,    output: 15,  cacheRead: 0.3,   cacheWrite: 3.75 },
  'claude-haiku-4-5':    { input: 0.8,  output: 4,   cacheRead: 0.08,  cacheWrite: 1 },
  'gpt-4o':              { input: 2.5,  output: 10,  cacheRead: 1.25,  cacheWrite: 2.5 },
  'gpt-4o-mini':         { input: 0.15, output: 0.6, cacheRead: 0.075, cacheWrite: 0.15 },
  'gpt-4.1':             { input: 2,    output: 8,   cacheRead: 0.5,   cacheWrite: 2 },
  'o3-mini':             { input: 1.1,  output: 4.4, cacheRead: 0.55,  cacheWrite: 1.1 },
  'o4-mini':             { input: 1.1,  output: 4.4, cacheRead: 0.55,  cacheWrite: 1.1 },
  'gemini-2.0-flash':    { input: 0.1,  output: 0.4, cacheRead: 0.025, cacheWrite: 0.1 },
  'gemini-2.5-pro':      { input: 1.25, output: 10,  cacheRead: 0.31,  cacheWrite: 1.25 },
}

/**
 * Find pricing for a model. Tries exact match first, then prefix match.
 * Custom pricing takes precedence.
 */
export function getModelPrice(model: string, customPricing?: Record<string, ModelPrice>): ModelPrice | undefined {
  // Custom pricing first
  if (customPricing?.[model]) return customPricing[model]

  // Exact match
  if (MODEL_PRICING[model]) return MODEL_PRICING[model]

  // Prefix match (e.g. 'claude-sonnet-4-5-20250929' -> 'claude-sonnet-4-5')
  for (const [key, price] of Object.entries(MODEL_PRICING)) {
    if (model.startsWith(key)) return price
  }

  // Custom pricing prefix match
  if (customPricing) {
    for (const [key, price] of Object.entries(customPricing)) {
      if (model.startsWith(key)) return price
    }
  }

  return undefined
}

/**
 * Compute cost in USD for a session's token usage.
 * Returns 0 for unknown models.
 */
export function computeCost(
  model: string,
  inputTokens: number,
  outputTokens: number,
  cacheReadTokens: number,
  cacheCreationTokens: number,
  customPricing?: Record<string, ModelPrice>,
): number {
  const price = getModelPrice(model, customPricing)
  if (!price) return 0

  const M = 1_000_000
  return (
    (inputTokens / M) * price.input +
    (outputTokens / M) * price.output +
    (cacheReadTokens / M) * price.cacheRead +
    (cacheCreationTokens / M) * price.cacheWrite
  )
}
