// src/tools/inspect_session.ts

import type { Database } from '../core/db.js';
import { buildSessionInspector } from '../core/session-inspector.js';

export const inspectSessionTool = {
  name: 'inspect_session',
  description:
    'Inspect derived facts, provenance, status, cost, parent/child rollup, LLM audit, and resume command for one session. Local read-only; does not call any external provider or CLI.',
  inputSchema: {
    type: 'object' as const,
    required: ['id'],
    properties: {
      id: { type: 'string', description: 'Session ID' },
    },
    additionalProperties: false,
  },
};

export interface InspectSessionResult {
  content: Array<{ type: 'text'; text: string }>;
  isError?: boolean;
}

export async function handleInspectSession(
  db: Database,
  params: { id: string },
): Promise<InspectSessionResult> {
  const inspector = buildSessionInspector(db, params.id);
  if (!inspector) {
    return {
      content: [
        { type: 'text' as const, text: `Session not found: ${params.id}` },
      ],
      isError: true,
    };
  }
  return {
    content: [
      { type: 'text' as const, text: JSON.stringify(inspector, null, 2) },
    ],
  };
}
