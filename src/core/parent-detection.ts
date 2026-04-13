// src/core/parent-detection.ts
// Layer 2: Content heuristic detection for agent→parent session linking.
// Pure functions — no DB or side effects.

/** Regex patterns that identify agent dispatch messages (first message of a subagent session). */
export const DISPATCH_PATTERNS = [
  /^<task>/i,
  /^Your task is to\b/i,
  /^You are a\b.*\bagent\b/i,
  /^You are a\b.*\bassistant\b/i,
  /^You are (?:implementing|reviewing|debugging)\b/i,
  /^Review the\b/i,
  /^Analyze (?:the |this |all )/i,
  /^IMPORTANT:\s*Do NOT/i,
  /^Generate a file named\b/i,
  /^(?:Read|Check|Verify|Audit|Inspect) the\b.*(?:code|file|implementation|spec|plan)/i,
];

/** Short messages that are clearly agent probes (exact match, case-insensitive) */
const PROBE_MESSAGES = new Set([
  'ping',
  'hello',
  'hi',
  'update',
  'test',
  'what is 2+2?',
  'what is 2+2? reply with just the number.',
  'reply with only the model name you are running as, nothing else',
]);

/**
 * Returns true if the message matches any dispatch pattern or known probe.
 * Empty messages (no summary) are also treated as dispatched.
 */
export function isDispatchPattern(firstMessage: string): boolean {
  if (!firstMessage) return true; // no summary = likely dispatched agent with no user message
  const trimmed = firstMessage.trim();
  if (trimmed.length === 0) return true;
  if (PROBE_MESSAGES.has(trimmed.toLowerCase())) return true;
  if (trimmed.length < 10) return false; // too short but not a known probe
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
  agentCwd?: string,
  parentCwd?: string,
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

  // Time proximity: exponential decay with 30min half-life
  // 5 min → 0.51, 30 min → 0.22, 2 hours → 0.005
  const diffSeconds = (agentStart - parentStart) / 1000;
  const timeScore = Math.exp(-diffSeconds / 1800) * 0.6;

  // Project/cwd match: exact project = 1.0 * 0.3, cwd overlap = 0.7 * 0.3, no match = 0
  let projectScore = 0;
  if (agentProject && parentProject && agentProject === parentProject) {
    projectScore = 1.0 * 0.3;
  } else if (agentCwd && parentCwd) {
    // cwd fallback: one is subdirectory of the other
    // Require at least 2 path components (exclude bare '/' matching everything)
    const normAgent = agentCwd.replace(/\/$/, '');
    const normParent = parentCwd.replace(/\/$/, '');
    const minLen = Math.min(normAgent.length, normParent.length);
    if (
      minLen > 1 &&
      (normAgent.startsWith(normParent) || normParent.startsWith(normAgent))
    ) {
      projectScore = 0.7 * 0.3;
    }
  }

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
