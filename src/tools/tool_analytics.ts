import type { Database } from '../core/db.js';
import type { Logger } from '../core/logger.js';

export function handleToolAnalytics(
  db: Database,
  params: { project?: string; since?: string; group_by?: string },
  opts?: { log?: Logger },
) {
  opts?.log?.info('tool_analytics invoked', {
    project: params.project,
    groupBy: params.group_by,
  });
  const tools = db.getToolAnalytics({
    project: params.project,
    since: params.since,
    groupBy: params.group_by,
  });

  const totalCalls = tools.reduce((sum, t) => sum + (t.callCount || 0), 0);
  const groupCount = tools.length;

  return { tools, totalCalls, groupCount };
}
