import type { LiveSessionMonitor } from '../core/live-sessions.js';
import type { Logger } from '../core/logger.js';

export const liveSessionsTool = {
  name: 'live_sessions',
  description:
    'List currently active coding sessions detected by file activity.',
  inputSchema: {
    type: 'object' as const,
    properties: {},
    additionalProperties: false,
  },
};

export function handleLiveSessions(
  monitor: LiveSessionMonitor | null,
  opts?: { log?: Logger },
) {
  opts?.log?.info('live_sessions invoked');
  if (!monitor) {
    return {
      sessions: [],
      count: 0,
      note: 'Live session monitor not available (MCP server mode)',
    };
  }
  const sessions = monitor.getSessions();
  return { sessions, count: sessions.length };
}
