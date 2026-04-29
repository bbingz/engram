// src/core/parent-detection.ts
// Layer 2: Content heuristic detection for agent→parent session linking.
// Pure functions — no DB or side effects.

/** Bump this when detection logic changes to trigger re-evaluation of unlinked sessions. */
export const DETECTION_VERSION = 4;

/** Regex patterns that identify agent dispatch messages (first message of a subagent session). */
export const DISPATCH_PATTERNS = [
  /(?:^|\n)\s*<task>/i,
  /(?:^|\n)\s*<user_action>/i,
  /(?:^|\n)\s*Your task is(?: to)?\b/i,
  /^You are a\b.*\bagent\b/i,
  /^You are a\b.*\bassistant\b/i,
  /^You are (?:implementing|reviewing|debugging|auditing|evaluating|performing)\b/i,
  /^Review the\b/i,
  /^Review this\b/i,
  /(?:^|\n)\s*(?:Review|Re-review|Perform|Evaluate|Investigate|Audit|Inspect|Check|Verify|Implement(?: Task \d+)?:?|Fix(?: Task \d+)?:?|Final (?:code quality|spec compliance) review)\b.*(?:\/Users\/|git diff|repo|repository|branch|spec|plan|implementation|code|diff|task|files?)/i,
  /^Analyze (?:the |this |all )/i,
  /^IMPORTANT:\s*Do NOT/i,
  /^Generate a file named\b/i,
  /^(?:Read|Check|Verify|Audit|Inspect) the\b.*(?:code|file|implementation|spec|plan)/i,
  // Context-constrained task verbs (require technical context to avoid matching normal chat)
  /^(?:Fix|Debug|Implement|Refactor|Write tests for)\s.*(?:\/|\.ts\b|\.js\b|\.py\b|\.swift\b|bug|issue|error|module|component|function)/i,
  /^(?:Context|Background|Instructions):\s/i,
  /^The following (?:code|changes|files|implementation)\b/i,
  /(?:^|\n)\s*<instructions>/i,
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
  'say hi',
  'say hello',
  'exit',
  'q',
  'quit',
  'list-skills',
  'auth login',
  'say: all fixes verified',
  'this prompt will fail',
]);

/** Regex patterns for agent probes that vary in content (e.g. randomized math questions) */
const PROBE_REGEXES: RegExp[] = [
  /^what is \d+\s*[+\-*/]\s*\d+\??$/i, // "What is 5+5?", "What is 1+1?"
  /^say (?:hello|hi)\b.{0,20}$/i, // "Say hello in 3 words"
  /^say exactly:\s*\S.{0,40}$/i, // "Say exactly: streaming works"
  /^echo\b/i, // "echo 'hello'"
  /^(?:reply|respond)\s+with\b/i, // "Reply with just the number"
];

/**
 * Returns true if the message matches any dispatch pattern or known probe.
 * Empty messages (no summary) are also treated as dispatched.
 */
export function isDispatchPattern(firstMessage: string): boolean {
  if (!firstMessage) return true; // no summary = likely dispatched agent with no user message
  const trimmed = firstMessage.trim();
  if (trimmed.length === 0) return true;
  if (PROBE_MESSAGES.has(trimmed.toLowerCase())) return true;
  if (PROBE_REGEXES.some((r) => r.test(trimmed))) return true;
  if (trimmed.length < 10) return false; // too short but not a known probe
  return DISPATCH_PATTERNS.some((p) => p.test(trimmed));
}

function normalizeCwd(cwd?: string): string | null {
  if (!cwd) return null;
  const normalized = cwd.replace(/\/+$/, '');
  return normalized.length > 0 ? normalized : null;
}

function classifyCwdRelation(
  agentCwd?: string,
  parentCwd?: string,
): 'exact' | 'nested' | 'unrelated' | 'unknown' {
  const normalizedAgent = normalizeCwd(agentCwd);
  const normalizedParent = normalizeCwd(parentCwd);
  if (!normalizedAgent || !normalizedParent) return 'unknown';
  if (normalizedAgent === normalizedParent) return 'exact';
  if (
    normalizedAgent.startsWith(`${normalizedParent}/`) ||
    normalizedParent.startsWith(`${normalizedAgent}/`)
  ) {
    return 'nested';
  }
  return 'unrelated';
}

/**
 * Score a candidate parent session for a given agent session.
 * Returns 0 for impossible matches, 0..1 for viable ones.
 *
 * Time proximity remains the dominant signal, but unrelated cwd values should not
 * out-rank a same-repo parent purely because they started a few minutes later.
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

  const cwdRelation = classifyCwdRelation(agentCwd, parentCwd);
  const hasProjectMatch =
    agentProject && parentProject && agentProject === parentProject;

  // end_time is the last indexed message timestamp, NOT when the user closed
  // the session. A parent can dispatch agents hours after its last message if
  // it was still open. So we treat ended-before-agent as a soft penalty rather
  // than a hard disqualifier — but only when the gap is reasonable (< 4h) and
  // there is CWD/project evidence linking them.
  let endedBeforeAgent = false;
  if (parentEndTime) {
    const parentEnd = new Date(parentEndTime).getTime();
    if (agentStart > parentEnd) {
      const gapMs = agentStart - parentEnd;
      const MAX_GAP_MS = 4 * 60 * 60 * 1000; // 4 hours
      // If unrelated CWD and parent ended before agent → hard reject
      if (cwdRelation === 'unrelated' || cwdRelation === 'unknown') return 0;
      // If gap > 4h even with matching CWD → hard reject
      if (gapMs > MAX_GAP_MS) return 0;
      endedBeforeAgent = true;
    }
  }

  // Time proximity: gentle exponential decay with 4h half-life.
  // CWD/project matching is the primary discriminator; time is a tiebreaker.
  const diffSeconds = (agentStart - parentStart) / 1000;
  const unrelatedCwdTimePenalty = cwdRelation === 'unrelated' ? 0.35 : 1;
  const timeScore =
    Math.exp(-diffSeconds / 14400) * 0.6 * unrelatedCwdTimePenalty;

  // Project/cwd match: exact project remains strongest. Exact cwd is almost as
  // strong because cross-tool dispatches normally stay inside the same repo.
  let projectScore = 0;
  if (hasProjectMatch) {
    projectScore = 1.0 * 0.3;
  } else if (cwdRelation === 'exact') {
    projectScore = 0.28;
  } else if (cwdRelation === 'nested') {
    projectScore = 0.24;
  }

  // Active bonus: still-running parents get higher bonus. Parents that ended
  // before the agent started get a reduced bonus (they were likely still open).
  let activeScore: number;
  if (!parentEndTime) {
    activeScore = 1.0 * 0.1; // still running
  } else if (endedBeforeAgent) {
    activeScore = 0.2 * 0.1; // ended before agent — small penalty
  } else {
    activeScore = 0.5 * 0.1; // ended after agent started
  }
  if (!hasProjectMatch && cwdRelation === 'unrelated') {
    activeScore = parentEndTime ? 0.01 : 0.02;
  }

  return timeScore + projectScore + activeScore;
}

/**
 * Pick the best candidate from a scored list.
 * Returns null for empty list or all-zero scores.
 *
 * When the top two candidates score within 5% of each other, the result
 * is considered ambiguous. We still return the highest-scoring candidate
 * because a possibly-wrong suggestion is more useful than no suggestion
 * — the user can correct it via the manual link API.
 */
export function pickBestCandidate(
  scored: { parentId: string; score: number }[],
): string | null {
  if (scored.length === 0) return null;

  // Sort descending by score
  const sorted = [...scored].sort((a, b) => b.score - a.score);
  const best = sorted[0];

  if (best.score === 0) return null;

  return best.parentId;
}
