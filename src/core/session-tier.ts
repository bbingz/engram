export type SessionTier = 'skip' | 'lite' | 'normal' | 'premium'

export interface TierInput {
  messageCount: number
  agentRole: string | null
  filePath: string
  project: string | null
  summary: string | null
  startTime: string | null
  endTime: string | null
  source: string
  isPreamble?: boolean
  assistantCount?: number
  toolCount?: number
}

const NOISE_PATTERNS = ['/usage', 'Generate a short, clear title']

function durationMinutes(startTime: string | null, endTime: string | null): number {
  if (!startTime || !endTime) return 0
  const start = new Date(startTime).getTime()
  const end = new Date(endTime).getTime()
  if (Number.isNaN(start) || Number.isNaN(end)) return 0
  return (end - start) / 60_000
}

export function computeTier(input: TierInput): SessionTier {
  // 1. skip
  // Preamble-only → skip
  if (input.isPreamble) return 'skip'
  // Probe sessions → skip
  if (input.filePath?.includes('/.engram/probes/')) return 'skip'
  if (input.agentRole != null) return 'skip'
  if (input.filePath.includes('/subagents/')) return 'skip'
  if (input.messageCount <= 1) return 'skip'
  // No-reply (multiple user messages but no AI response) → lite
  // Only apply when assistantCount is explicitly known (not just absent)
  if (
    input.assistantCount !== undefined &&
    input.assistantCount === 0 &&
    (input.toolCount ?? 0) === 0
  ) return 'lite'

  // 2. premium
  if (input.messageCount >= 20) return 'premium'
  if (input.messageCount >= 10 && input.project != null) return 'premium'
  if (durationMinutes(input.startTime, input.endTime) > 30) return 'premium'

  // 3. lite
  if (input.summary && NOISE_PATTERNS.some(p => input.summary!.includes(p))) return 'lite'

  // 4. normal
  return 'normal'
}
