// src/core/session-scoring.ts
// Pure scoring function — no DB access. Takes session data, returns 0-100 quality score.

export interface ScoringInput {
  userCount: number;
  assistantCount: number;
  toolCount: number;
  systemCount: number;
  startTime?: string | null;
  endTime?: string | null;
  project?: string | null;
}

function durationMinutes(
  startTime?: string | null,
  endTime?: string | null,
): number {
  if (!startTime || !endTime) return 0;
  const start = new Date(startTime).getTime();
  const end = new Date(endTime).getTime();
  if (Number.isNaN(start) || Number.isNaN(end)) return 0;
  return (end - start) / 60_000;
}

/**
 * Compute a 0-100 quality score for a session.
 *
 * Factors:
 * - Turn ratio (0-30): interactivity — alternating user/assistant pairs
 * - Tool engagement (0-25): tool usage relative to assistant messages
 * - Session density (0-20): optimal duration 5-60 min
 * - Project association (0-15): has known project
 * - Message volume (0-10): more messages = more substance
 */
export function computeQualityScore(session: ScoringInput): number {
  const { userCount, assistantCount, toolCount, project } = session;
  const totalMessages =
    userCount + assistantCount + toolCount + session.systemCount;

  // Turn ratio (0-30): high interactivity = higher score
  let turnScore = 0;
  if (userCount > 0 && assistantCount > 0) {
    const pairs = Math.min(userCount, assistantCount);
    turnScore = Math.min(30, (pairs / totalMessages) * 30);
  }

  // Tool engagement (0-25): tools suggest productive work
  let toolScore = 0;
  if (assistantCount > 0) {
    toolScore = Math.min(25, (toolCount / assistantCount) * 50);
  }

  // Session density (0-20): 5-60 min is optimal
  const duration = durationMinutes(session.startTime, session.endTime);
  let densityScore = 0;
  if (duration < 1) {
    densityScore = 0;
  } else if (duration <= 5) {
    // Ramp up: 1-5 min → 0-20 linearly
    densityScore = (duration / 5) * 20;
  } else if (duration <= 60) {
    densityScore = 20;
  } else if (duration <= 180) {
    // Taper: 60-180 min → 20-10 linearly
    densityScore = 20 - ((duration - 60) / 120) * 10;
  } else {
    densityScore = 10;
  }

  // Project association (0-15)
  const projectScore = project ? 15 : 0;

  // Message volume (0-10)
  const messageCount = userCount + assistantCount + toolCount;
  const volumeScore = Math.min(10, messageCount / 5);

  const raw = turnScore + toolScore + densityScore + projectScore + volumeScore;
  return Math.max(0, Math.min(100, Math.round(raw)));
}
