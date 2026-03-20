import { describe, it, expect } from 'vitest'
import { computeCost, getModelPrice } from '../../src/core/pricing.js'

describe('pricing', () => {
  describe('getModelPrice', () => {
    it('returns exact match', () => {
      const price = getModelPrice('claude-sonnet-4-6')
      expect(price).toBeDefined()
      expect(price!.input).toBe(3)
      expect(price!.output).toBe(15)
    })

    it('matches versioned model by prefix', () => {
      const price = getModelPrice('claude-sonnet-4-5-20250929')
      expect(price).toBeDefined()
      expect(price!.input).toBe(3)
    })

    it('returns undefined for unknown model', () => {
      expect(getModelPrice('totally-unknown-model')).toBeUndefined()
    })

    it('uses custom pricing override', () => {
      const custom = { 'my-model': { input: 99, output: 99, cacheRead: 9, cacheWrite: 9 } }
      const price = getModelPrice('my-model', custom)
      expect(price).toBeDefined()
      expect(price!.input).toBe(99)
    })
  })

  describe('computeCost', () => {
    it('computes cost for known model', () => {
      // claude-sonnet-4-6: input=3, output=15, cacheRead=0.3, cacheWrite=3.75 per 1M
      const cost = computeCost('claude-sonnet-4-6', 1_000_000, 100_000, 500_000, 200_000)
      // input: 3.0, output: 1.5, cacheRead: 0.15, cacheWrite: 0.75 = 5.4
      expect(cost).toBeCloseTo(5.4, 1)
    })

    it('returns 0 for unknown model', () => {
      expect(computeCost('unknown-model', 1000, 500, 0, 0)).toBe(0)
    })

    it('handles zero tokens', () => {
      expect(computeCost('claude-sonnet-4-6', 0, 0, 0, 0)).toBe(0)
    })
  })
})
