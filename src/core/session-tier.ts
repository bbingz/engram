export type SessionTier = 'skip' | 'lite' | 'normal' | 'premium';

export interface TierInput {
  messageCount: number;
  agentRole: string | null;
  filePath: string;
  project: string | null;
  summary: string | null;
  startTime: string | null;
  endTime: string | null;
  source: string;
  isPreamble?: boolean;
  assistantCount?: number;
  toolCount?: number;
}

const NOISE_PATTERNS = [
  '/usage',
  'Generate a short, clear title',
  'Reply exactly:',
  'Reply with exactly:',
  'reply with just',
  '/status/exit',
];

/** Probe patterns — single-line messages that are tool probes, not real sessions.
 * Entries MUST be lowercase: the matcher applies `toLowerCase().trim()` first. */
const PROBE_FIRST_LINES = new Set([
  'ping',
  'hi',
  'hello',
  'test',
  'echo',
  'ok',
  'hey',
  'say hello',
  'reply: t4',
]);

function durationMinutes(
  startTime: string | null,
  endTime: string | null,
): number {
  if (!startTime || !endTime) return 0;
  const start = new Date(startTime).getTime();
  const end = new Date(endTime).getTime();
  if (!Number.isFinite(start) || !Number.isFinite(end)) return 0;
  const duration = (end - start) / 60_000;
  return Number.isFinite(duration) ? duration : 0;
}

export function computeTier(input: TierInput): SessionTier {
  // 1. skip
  // Preamble-only → skip
  if (input.isPreamble) return 'skip';
  // Probe sessions → skip
  if (input.filePath?.includes('/.engram/probes/')) return 'skip';
  if (input.agentRole != null) return 'skip';
  if (input.filePath.includes('/subagents/')) return 'skip';
  if (input.messageCount <= 1) return 'skip';
  // No-reply (multiple user messages but no AI response) → lite
  // Only apply when assistantCount is explicitly known (not just absent)
  if (
    input.assistantCount !== undefined &&
    input.assistantCount === 0 &&
    (input.toolCount ?? 0) === 0
  )
    return 'lite';

  // Probe sessions with very few messages are likely tooling noise.
  if (
    input.messageCount <= 3 &&
    input.summary &&
    PROBE_FIRST_LINES.has(input.summary.toLowerCase().trim())
  )
    return 'lite';

  // 2. premium
  if (input.messageCount >= 20) return 'premium';
  if (input.messageCount >= 10 && input.project != null) return 'premium';
  if (durationMinutes(input.startTime, input.endTime) > 30) return 'premium';

  // 3. lite
  if (input.summary && NOISE_PATTERNS.some((p) => input.summary?.includes(p)))
    return 'lite';

  // 4. normal
  return 'normal';
}
