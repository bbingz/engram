// src/core/parent-detection.ts
// Layer 2: Content heuristic detection for agent→parent session linking.
// Pure functions — no DB or side effects.

/** Regex patterns that identify agent dispatch messages (first message of a subagent session). */
export const DISPATCH_PATTERNS = [
  /^<task>/i,
  /^Your task is to\b/i,
  /^You are a\b.*\bagent\b/i,
  /^You are a\b.*\bassistant\b/i,
  /^<TASK>/,
  /^Review the (?:following|code|implementation)\b/i,
  /^Analyze (?:the |this )/i,
];

/**
 * Returns true if the message matches any dispatch pattern.
 * Short/empty messages are rejected outright.
 */
export function isDispatchPattern(firstMessage: string): boolean {
  if (!firstMessage || firstMessage.length < 10) return false;
  const trimmed = firstMessage.trim();
  return DISPATCH_PATTERNS.some((p) => p.test(trimmed));
}

/**
 * Score a candidate parent session for a given agent session.
 * Returns 0 for impossible matches, 0..1 for viable ones.
 *
 * Weights: time proximity 60%, project match 30%, active session bonus 10%.
 */
export function scoreCandidate(
  agentStartTime: string,
  parentStartTime: string,
  parentEndTime: string | null,
  agentProject: string | null,
  parentProject: string | null,
): number {
  const agentStart = new Date(agentStartTime).getTime();
  const parentStart = new Date(parentStartTime).getTime();

  // Agent must start after parent
  if (agentStart < parentStart) return 0;

  // Agent must start before parent ended (if parent has ended)
  if (parentEndTime) {
    const parentEnd = new Date(parentEndTime).getTime();
    if (agentStart > parentEnd) return 0;
  }

  // Time proximity: 1 / (1 + diffSeconds) * 0.6
  const diffSeconds = (agentStart - parentStart) / 1000;
  const timeScore = (1 / (1 + diffSeconds)) * 0.6;

  // Project match: exact match = 1.0 * 0.3, no match = 0
  const projectScore =
    agentProject && parentProject && agentProject === parentProject
      ? 1.0 * 0.3
      : 0;

  // Active bonus: no end_time = 1.0 * 0.1, ended = 0.5 * 0.1
  const activeScore = parentEndTime ? 0.5 * 0.1 : 1.0 * 0.1;

  return timeScore + projectScore + activeScore;
}

/**
 * Pick the best candidate from a scored list.
 * Returns null for empty list, all-zero scores, or ambiguous results
 * (top 2 within 15% of each other).
 */
export function pickBestCandidate(
  scored: { parentId: string; score: number }[],
): string | null {
  if (scored.length === 0) return null;

  // Sort descending by score
  const sorted = [...scored].sort((a, b) => b.score - a.score);
  const best = sorted[0];

  if (best.score === 0) return null;

  // Ambiguity rejection: if top 2 differ by < 15%, reject
  if (sorted.length >= 2) {
    const second = sorted[1];
    const gap = (best.score - second.score) / best.score;
    if (gap < 0.15) return null;
  }

  return best.parentId;
}
