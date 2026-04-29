// src/tools/get_insights.ts

import type { FileSettings } from '../core/config.js';
import {
  type CostSuggestion,
  getCostSuggestions,
} from '../core/cost-advisor.js';
import type { Database } from '../core/db.js';

export const getInsightsDefinition = {
  name: 'get_insights',
  description:
    'Get actionable cost optimization suggestions with savings estimates',
  inputSchema: {
    type: 'object' as const,
    properties: {
      since: {
        type: 'string',
        description:
          'ISO timestamp for start of analysis window (default: 7 days ago)',
      },
    },
    additionalProperties: false,
  },
};

const SEVERITY_ICON: Record<CostSuggestion['severity'], string> = {
  high: '🔴',
  medium: '🟡',
  low: '🟢',
};

function fmt(n: number): string {
  return `$${n.toFixed(2)}`;
}

function formatSuggestion(s: CostSuggestion): string {
  const icon = SEVERITY_ICON[s.severity];
  const lines: string[] = [`${icon} **${s.title}**`, s.detail];

  if (s.savings) {
    const savingsAmt = s.savings.current - s.savings.projected;
    lines.push(
      `  → Potential savings: ${fmt(savingsAmt)} (${s.savings.percent}%) over ${s.savings.period}`,
    );
  }

  if (s.topItems && s.topItems.length > 0) {
    for (const item of s.topItems) {
      lines.push(`  • ${item.label}: ${item.value}`);
    }
  }

  return lines.join('\n');
}

export async function handleGetInsights(
  db: Database,
  config: FileSettings,
  args: { since?: string },
): Promise<{ content: Array<{ type: 'text'; text: string }> }> {
  const result = getCostSuggestions(db, config, { since: args.since });
  const { suggestions, summary } = result;

  const lines: string[] = [];

  lines.push('## Cost Insights');
  lines.push('');
  lines.push(
    `**Period summary:** Spent ${fmt(summary.totalSpent)} · Projected monthly ${fmt(summary.projectedMonthly)}`,
  );
  if (summary.potentialSavings > 0) {
    lines.push(`**Potential savings:** ${fmt(summary.potentialSavings)}`);
  }
  lines.push('');

  if (suggestions.length === 0) {
    lines.push(
      'No cost optimization suggestions for this period. Spending looks healthy!',
    );
  } else {
    lines.push(
      `Found **${suggestions.length}** suggestion${suggestions.length > 1 ? 's' : ''}:`,
    );
    lines.push('');
    for (const s of suggestions) {
      lines.push(formatSuggestion(s));
      lines.push('');
    }
  }

  return {
    content: [{ type: 'text', text: lines.join('\n') }],
  };
}
