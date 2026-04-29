import type { Database } from '../core/db.js';
import type { Logger } from '../core/logger.js';

export const toolAnalyticsTool = {
  name: 'tool_analytics',
  description:
    'Analyze which tools (Read, Edit, Bash, etc.) are used most across sessions.',
  inputSchema: {
    type: 'object' as const,
    properties: {
      project: {
        type: 'string',
        description: 'Filter by project name (partial match)',
      },
      since: { type: 'string', description: 'Start time (ISO 8601)' },
      group_by: {
        type: 'string',
        enum: ['tool', 'session', 'project'],
        description: 'Group dimension (default: tool)',
      },
    },
    additionalProperties: false,
  },
};

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
