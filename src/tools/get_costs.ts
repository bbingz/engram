import type { Database } from '../core/db.js';
import type { Logger } from '../core/logger.js';

export function handleGetCosts(
  db: Database,
  params: { group_by?: string; since?: string; until?: string },
  opts?: { log?: Logger },
) {
  opts?.log?.info('get_costs invoked', {
    groupBy: params.group_by,
    since: params.since,
  });
  const breakdown = db.getCostsSummary({
    groupBy: params.group_by,
    since: params.since,
    until: params.until,
  });

  const totalCostUsd = breakdown.reduce((sum, r) => sum + (r.costUsd || 0), 0);
  const totalInputTokens = breakdown.reduce(
    (sum, r) => sum + (r.inputTokens || 0),
    0,
  );
  const totalOutputTokens = breakdown.reduce(
    (sum, r) => sum + (r.outputTokens || 0),
    0,
  );

  return {
    totalCostUsd: Math.round(totalCostUsd * 100) / 100,
    totalInputTokens,
    totalOutputTokens,
    breakdown,
  };
}
