// src/cli/utils.ts
// Shared CLI utilities

/**
 * Parse a relative duration string (e.g. '1h', '30m', '7d') into an ISO timestamp
 * representing that duration ago from now.
 */
export function parseDuration(duration: string): string {
  const match = duration.match(/^(\d+)(m|h|d)$/)
  if (!match) throw new Error(`Invalid duration: ${duration}. Use format: 30m, 1h, 7d`)
  const value = parseInt(match[1], 10)
  const unit = match[2]
  const ms = unit === 'm' ? value * 60000 : unit === 'h' ? value * 3600000 : value * 86400000
  return new Date(Date.now() - ms).toISOString()
}
