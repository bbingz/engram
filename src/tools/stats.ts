// src/tools/stats.ts
import type { Database } from '../core/db.js';
import type { Logger } from '../core/logger.js';

export async function handleStats(
  db: Database,
  params: {
    since?: string;
    until?: string;
    group_by?: string;
    exclude_noise?: boolean;
  },
  opts?: { log?: Logger },
): Promise<{
  groupBy: string;
  groups: {
    key: string;
    sessionCount: number;
    messageCount: number;
    userMessageCount: number;
    assistantMessageCount: number;
    toolMessageCount: number;
  }[];
  totalSessions: number;
}> {
  opts?.log?.info('stats invoked', {
    groupBy: params.group_by,
    since: params.since,
  });
  const groupBy = params.group_by ?? 'source';
  const groups = db.statsGroupBy(groupBy, params.since, params.until, {
    excludeNoise: params.exclude_noise,
  });
  const totalSessions = groups.reduce((sum, g) => sum + g.sessionCount, 0);

  return { groupBy, groups, totalSessions };
}
