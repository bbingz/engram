// src/core/cost-advisor.ts

import type { FileSettings } from './config.js';
import type { Database } from './db.js';
import { getModelPrice, MODEL_PRICING } from './pricing.js';

// ── Types ────────────────────────────────────────────────────────────────────

export interface SavingsEstimate {
  current: number; // USD
  projected: number; // USD
  percent: number; // 0-100
  period: string; // e.g. "7 days"
}

export interface TopItem {
  label: string;
  value: string | number;
}

export interface CostSuggestion {
  rule: string;
  severity: 'high' | 'medium' | 'low';
  title: string;
  detail: string;
  savings?: SavingsEstimate;
  topItems?: TopItem[];
}

export interface CostSuggestionSummary {
  totalSpent: number;
  projectedMonthly: number;
  potentialSavings: number;
}

export interface CostSuggestionResult {
  suggestions: CostSuggestion[];
  summary: CostSuggestionSummary;
}

export interface CostAdvisorOptions {
  since?: string;
}

// ── Helpers ──────────────────────────────────────────────────────────────────

function sinceIso(days: number): string {
  const d = new Date();
  d.setDate(d.getDate() - days);
  return d.toISOString();
}

function sinceNDaysAgo(days: number, base: Date = new Date()): string {
  const d = new Date(base);
  d.setDate(d.getDate() - days);
  return d.toISOString();
}

function fmt(n: number): string {
  return `$${n.toFixed(2)}`;
}

// ── Rule implementations ─────────────────────────────────────────────────────

/** Rule 1: Opus overuse — Opus cost >70% of total */
function ruleOpusOveruse(
  db: Database,
  since: string,
  totalCost: number,
): CostSuggestion | null {
  if (totalCost === 0) return null;

  const byModel = db.getCostsSummary({ groupBy: 'model', since });
  const opusRow = byModel.find(
    (r: any) => typeof r.key === 'string' && r.key.includes('opus'),
  );
  if (!opusRow) return null;

  const opusCost: number = opusRow.costUsd || 0;
  if (opusCost / totalCost < 0.7) return null;

  // Find Opus and Sonnet pricing to compute savings ratio
  const opusPrice = getModelPrice(opusRow.key as string);
  // Pick best sonnet alternative
  const sonnetKey = Object.keys(MODEL_PRICING).find((k) =>
    k.includes('sonnet'),
  );
  const sonnetPrice = sonnetKey ? MODEL_PRICING[sonnetKey] : null;

  let savingsPercent = 80; // default ~80% savings
  if (opusPrice && sonnetPrice) {
    // input token cost ratio (main driver for short sessions)
    savingsPercent = Math.round(
      (1 - sonnetPrice.input / opusPrice.input) * 100,
    );
  }

  // Count short Opus sessions (< 20 messages)
  const rawDb = db.getRawDb();
  const shortSessions = rawDb
    .prepare(`
    SELECT COUNT(*) as cnt FROM session_costs c
    JOIN sessions s ON c.session_id = s.id
    WHERE c.model LIKE '%opus%'
      AND s.message_count < 20
      AND s.start_time >= ?
  `)
    .get(since) as { cnt: number };

  const shortCount = shortSessions?.cnt ?? 0;
  if (shortCount === 0) return null;

  // Estimate savings: short sessions account for portion of opus cost
  const avgOpusCostPerSession = opusCost / (opusRow.sessionCount || 1);
  const shortSessionsCost = avgOpusCostPerSession * shortCount;
  const projectedSavings = shortSessionsCost * (savingsPercent / 100);

  return {
    rule: 'opus-overuse',
    severity: 'high',
    title: 'Opus used for short sessions',
    detail: `${shortCount} short Opus sessions (<20 messages) account for significant cost. Sonnet is ${savingsPercent}% cheaper for these tasks.`,
    savings: {
      current: opusCost,
      projected: opusCost - projectedSavings,
      percent: savingsPercent,
      period: '7 days',
    },
    topItems: [
      { label: 'Opus cost', value: fmt(opusCost) },
      { label: 'Short sessions', value: shortCount },
      {
        label: 'Cost share',
        value: `${Math.round((opusCost / totalCost) * 100)}%`,
      },
    ],
  };
}

/** Rule 2: Low cache rate — cache_read/(input+cache_read) <30%, Anthropic only */
function ruleLowCacheRate(db: Database, since: string): CostSuggestion | null {
  const rawDb = db.getRawDb();
  const row = rawDb
    .prepare(`
    SELECT
      SUM(c.cache_read_tokens) as cacheRead,
      SUM(c.input_tokens) as inputTokens,
      SUM(c.cost_usd) as totalCost
    FROM session_costs c
    JOIN sessions s ON c.session_id = s.id
    WHERE c.model LIKE 'claude-%'
      AND s.start_time >= ?
  `)
    .get(since) as {
    cacheRead: number;
    inputTokens: number;
    totalCost: number;
  } | null;

  if (!row?.inputTokens) return null;

  const cacheRead = row.cacheRead || 0;
  const inputTokens = row.inputTokens || 0;
  const total = inputTokens + cacheRead;

  if (total === 0) return null;

  const cacheRate = cacheRead / total;
  if (cacheRate >= 0.3) return null;

  const cacheRatePercent = Math.round(cacheRate * 100);

  return {
    rule: 'low-cache-rate',
    severity: 'medium',
    title: 'Low prompt cache utilization',
    detail: `Only ${cacheRatePercent}% of Anthropic input tokens are served from cache (target: ≥30%). Enable prompt caching to reduce costs on repeated context.`,
    topItems: [
      { label: 'Cache rate', value: `${cacheRatePercent}%` },
      { label: 'Cache reads', value: cacheRead.toLocaleString() },
      { label: 'Total input', value: total.toLocaleString() },
    ],
  };
}

/** Rule 3: Over budget — 7-day daily avg > dailyBudget */
function ruleOverBudget(
  _db: Database,
  config: FileSettings,
  _since: string,
  totalCost: number,
  periodDays: number,
): CostSuggestion | null {
  const dailyBudget =
    config.costAlerts?.dailyBudget ?? (config.monitor as any)?.dailyCostBudget;
  if (dailyBudget == null) return null;

  const dailyAvg = totalCost / periodDays;
  if (dailyAvg <= dailyBudget) return null;

  const overagePercent = Math.round(
    ((dailyAvg - dailyBudget) / dailyBudget) * 100,
  );

  return {
    rule: 'over-budget',
    severity: 'high',
    title: 'Daily spending exceeds budget',
    detail: `Average daily spend ${fmt(dailyAvg)} exceeds budget ${fmt(dailyBudget)} by ${overagePercent}%.`,
    topItems: [
      { label: 'Daily average', value: fmt(dailyAvg) },
      { label: 'Daily budget', value: fmt(dailyBudget) },
      { label: 'Over by', value: `${overagePercent}%` },
    ],
  };
}

/** Rule 4: Project hotspot — single project >50% of total cost */
function ruleProjectHotspot(
  db: Database,
  since: string,
  totalCost: number,
): CostSuggestion | null {
  if (totalCost === 0) return null;

  const byProject = db.getCostsSummary({ groupBy: 'project', since });
  if (byProject.length === 0) return null;

  const top = byProject[0] as {
    key: string;
    costUsd: number;
    sessionCount: number;
  };
  const share = (top.costUsd || 0) / totalCost;

  if (share < 0.5) return null;

  const sharePercent = Math.round(share * 100);

  return {
    rule: 'project-hotspot',
    severity: 'medium',
    title: 'Single project dominates spending',
    detail: `Project "${top.key}" accounts for ${sharePercent}% of total cost (${fmt(top.costUsd || 0)}).`,
    topItems: byProject.slice(0, 3).map((r: any) => ({
      label: r.key || '(unknown)',
      value: fmt(r.costUsd || 0),
    })),
  };
}

/** Rule 5: Model efficiency — ≥2 models → cost-per-session ranking */
function ruleModelEfficiency(
  db: Database,
  since: string,
): CostSuggestion | null {
  const byModel = db.getCostsSummary({ groupBy: 'model', since });
  if (byModel.length < 2) return null;

  const ranked = byModel
    .filter((r: any) => (r.sessionCount || 0) > 0)
    .map((r: any) => ({
      model: r.key as string,
      costPerSession: (r.costUsd || 0) / r.sessionCount,
      sessionCount: r.sessionCount as number,
      costUsd: r.costUsd as number,
    }))
    .sort((a, b) => b.costPerSession - a.costPerSession);

  if (ranked.length < 2) return null;

  const mostExpensive = ranked[0];
  const cheapest = ranked[ranked.length - 1];

  // Only flag if ratio >= 2x
  if (mostExpensive.costPerSession < cheapest.costPerSession * 2) return null;

  const ratio = Math.round(
    mostExpensive.costPerSession / cheapest.costPerSession,
  );

  return {
    rule: 'model-efficiency',
    severity: 'low',
    title: 'Large cost variance across models',
    detail: `${mostExpensive.model} costs ${ratio}x more per session than ${cheapest.model}. Consider migrating appropriate tasks to cheaper models.`,
    topItems: ranked.slice(0, 4).map((r) => ({
      label: r.model,
      value: `${fmt(r.costPerSession)}/session`,
    })),
  };
}

/** Rule 6: Expensive sessions — single session >$5 AND >200K tokens */
function ruleExpensiveSessions(
  db: Database,
  since: string,
): CostSuggestion | null {
  const rawDb = db.getRawDb();
  const rows = rawDb
    .prepare(`
    SELECT c.session_id, c.cost_usd, c.model,
           (c.input_tokens + c.output_tokens + c.cache_read_tokens + c.cache_creation_tokens) as total_tokens,
           s.summary
    FROM session_costs c
    JOIN sessions s ON c.session_id = s.id
    WHERE c.cost_usd > 5
      AND (c.input_tokens + c.output_tokens + c.cache_read_tokens + c.cache_creation_tokens) > 200000
      AND s.start_time >= ?
    ORDER BY c.cost_usd DESC
    LIMIT 5
  `)
    .all(since) as Array<{
    session_id: string;
    cost_usd: number;
    model: string;
    total_tokens: number;
    summary: string | null;
  }>;

  if (rows.length === 0) return null;

  const totalExpensiveCost = rows.reduce((s, r) => s + r.cost_usd, 0);

  return {
    rule: 'expensive-sessions',
    severity: 'medium',
    title: `${rows.length} very expensive session${rows.length > 1 ? 's' : ''} detected`,
    detail: `${rows.length} session${rows.length > 1 ? 's' : ''} each cost >$5 with >200K tokens. Consider breaking large tasks into smaller sessions.`,
    topItems: rows.slice(0, 3).map((r) => ({
      label: r.summary ? r.summary.slice(0, 50) : r.session_id.slice(0, 16),
      value: fmt(r.cost_usd),
    })),
    savings: {
      current: totalExpensiveCost,
      projected: totalExpensiveCost * 0.5,
      percent: 50,
      period: '7 days',
    },
  };
}

/** Rule 7: Week-over-week spike — this week > last week × 1.5 */
function ruleWeekOverWeekSpike(db: Database): CostSuggestion | null {
  const now = new Date();
  const thisWeekSince = sinceNDaysAgo(7, now);
  const lastWeekSince = sinceNDaysAgo(14, now);
  const lastWeekUntil = thisWeekSince;

  const rawDb = db.getRawDb();

  const thisWeekRow = rawDb
    .prepare(`
    SELECT SUM(c.cost_usd) as cost
    FROM session_costs c
    JOIN sessions s ON c.session_id = s.id
    WHERE s.start_time >= ?
  `)
    .get(thisWeekSince) as { cost: number } | null;

  const lastWeekRow = rawDb
    .prepare(`
    SELECT SUM(c.cost_usd) as cost
    FROM session_costs c
    JOIN sessions s ON c.session_id = s.id
    WHERE s.start_time >= ? AND s.start_time < ?
  `)
    .get(lastWeekSince, lastWeekUntil) as { cost: number } | null;

  const thisWeek = thisWeekRow?.cost || 0;
  const lastWeek = lastWeekRow?.cost || 0;

  if (lastWeek === 0 || thisWeek <= lastWeek * 1.5) return null;

  const spikePercent = Math.round(((thisWeek - lastWeek) / lastWeek) * 100);

  return {
    rule: 'wow-spike',
    severity: 'high',
    title: 'Week-over-week spending spike',
    detail: `Spending increased ${spikePercent}% this week (${fmt(thisWeek)}) vs last week (${fmt(lastWeek)}).`,
    topItems: [
      { label: 'This week', value: fmt(thisWeek) },
      { label: 'Last week', value: fmt(lastWeek) },
      { label: 'Change', value: `+${spikePercent}%` },
    ],
  };
}

/** Rule 8: Output imbalance — output/input >3, excluding sessions with >10 Write/Edit calls */
function ruleOutputImbalance(
  db: Database,
  since: string,
): CostSuggestion | null {
  const rawDb = db.getRawDb();

  // Get sessions where output >> input, excluding heavy file-editing sessions
  const rows = rawDb
    .prepare(`
    SELECT c.session_id, c.input_tokens, c.output_tokens, c.cost_usd, c.model
    FROM session_costs c
    JOIN sessions s ON c.session_id = s.id
    WHERE c.input_tokens > 0
      AND CAST(c.output_tokens AS REAL) / c.input_tokens > 3
      AND s.start_time >= ?
  `)
    .all(since) as Array<{
    session_id: string;
    input_tokens: number;
    output_tokens: number;
    cost_usd: number;
    model: string;
  }>;

  if (rows.length === 0) return null;

  // Filter out sessions with >10 Write/Edit tool calls (batch query, not N+1)
  const sessionIds = rows.map((r) => r.session_id);
  const editCounts = new Map<string, number>();
  if (sessionIds.length > 0) {
    const placeholders = sessionIds.map(() => '?').join(',');
    const toolRows = rawDb
      .prepare(`
      SELECT session_id, COALESCE(SUM(call_count), 0) as cnt
      FROM session_tools
      WHERE session_id IN (${placeholders})
        AND tool_name IN ('Write', 'Edit', 'MultiEdit')
      GROUP BY session_id
    `)
      .all(...sessionIds) as Array<{ session_id: string; cnt: number }>;
    for (const tr of toolRows) editCounts.set(tr.session_id, tr.cnt);
  }
  const filtered = rows.filter(
    (row) => (editCounts.get(row.session_id) || 0) <= 10,
  );

  if (filtered.length === 0) return null;

  const totalOutputCost = filtered.reduce((s, r) => {
    const price = getModelPrice(r.model);
    if (!price) return s;
    return s + (r.output_tokens / 1_000_000) * price.output;
  }, 0);

  const avgRatio =
    filtered.reduce((s, r) => s + r.output_tokens / r.input_tokens, 0) /
    filtered.length;

  return {
    rule: 'output-imbalance',
    severity: 'medium',
    title: 'High output-to-input token ratio',
    detail: `${filtered.length} session${filtered.length > 1 ? 's' : ''} have output/input ratio >${Math.round(avgRatio)}x (avg). Verbose responses may be inflating cost.`,
    topItems: [
      { label: 'Sessions affected', value: filtered.length },
      { label: 'Avg output/input ratio', value: `${Math.round(avgRatio)}x` },
      { label: 'Est. output cost', value: fmt(totalOutputCost) },
    ],
  };
}

// ── Main export ───────────────────────────────────────────────────────────────

export function getCostSuggestions(
  db: Database,
  config: FileSettings,
  options?: CostAdvisorOptions,
): CostSuggestionResult {
  const periodDays = 7;
  const since = options?.since ?? sinceIso(periodDays);

  // Get total cost for the period
  const rawDb = db.getRawDb();
  const totalRow = rawDb
    .prepare(`
    SELECT SUM(c.cost_usd) as cost
    FROM session_costs c
    JOIN sessions s ON c.session_id = s.id
    WHERE s.start_time >= ?
  `)
    .get(since) as { cost: number } | null;

  const totalCost = totalRow?.cost || 0;
  const projectedMonthly = (totalCost / periodDays) * 30;

  // Run all rules
  const candidates: Array<CostSuggestion | null> = [
    ruleOpusOveruse(db, since, totalCost),
    ruleLowCacheRate(db, since),
    ruleOverBudget(db, config, since, totalCost, periodDays),
    ruleProjectHotspot(db, since, totalCost),
    ruleModelEfficiency(db, since),
    ruleExpensiveSessions(db, since),
    ruleWeekOverWeekSpike(db),
    ruleOutputImbalance(db, since),
  ];

  const suggestions = candidates.filter((s): s is CostSuggestion => s !== null);

  // Compute potential savings from suggestions that have estimates
  const potentialSavings = suggestions.reduce((sum, s) => {
    if (s.savings) {
      return sum + (s.savings.current - s.savings.projected);
    }
    return sum;
  }, 0);

  return {
    suggestions,
    summary: {
      totalSpent: totalCost,
      projectedMonthly,
      potentialSavings,
    },
  };
}
