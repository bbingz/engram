// src/core/session-inspector.ts — pure local inspector builder.
// Aggregates session, cost, parent/child, and audit facts from SQLite into
// a single read-only DTO. No external LLM calls, no transcript streaming.

import type { Database } from './db.js';
import {
  buildResumeInspection,
  type ResumeInspection,
} from './resume-coordinator.js';

export type SessionStatusLabel =
  | 'done'
  | 'in_progress'
  | 'waiting'
  | 'errored'
  | 'abandoned'
  | 'unknown';

export type SummaryProvenance =
  | 'adapter_first_message'
  | 'engram_llm_manual'
  | 'engram_llm_auto'
  | 'upstream_compact'
  | 'fallback'
  | 'unknown';

export type DerivedFieldProvenance =
  | 'database'
  | 'ai_audit'
  | 'source_transcript'
  | 'rule'
  | 'heuristic'
  | 'fallback'
  | 'unknown';

export type LlmAuditTrigger = 'manual' | 'auto' | 'indexing' | 'unknown';
export type LlmAuditCaller = 'summary' | 'title' | 'embedding';

export interface SessionInspectorStatus {
  label: SessionStatusLabel;
  confidence: 'high' | 'medium' | 'low';
  source: 'rule' | 'live_probe' | 'llm' | 'fallback' | 'unknown';
  basisTags: string[];
  observedAt?: string;
}

export interface SessionInspector {
  session: {
    id: string;
    source: string;
    project?: string;
    cwd?: string;
    model?: string;
    startTime?: string;
    endTime?: string;
    messageCount: number;
    filePath?: string;
    tier?: 'skip' | 'lite' | 'normal' | 'premium';
    agentRole?: string;
  };
  provenance: {
    transcript: 'local_file' | 'database_snapshot' | 'missing';
    title: DerivedFieldProvenance;
    cost: DerivedFieldProvenance;
    parentLink: DerivedFieldProvenance;
  };
  summaries: {
    displayTitle?: string;
    firstMessageSummary?: string;
    storedSummary?: string;
    llmSummary?: string;
    compactSummary?: string;
    summaryMessageCount?: number;
    isSummaryStale?: boolean;
    provenance: {
      firstMessageSummary: SummaryProvenance;
      storedSummary: SummaryProvenance;
      llmSummary: SummaryProvenance;
      compactSummary: SummaryProvenance;
    };
  };
  status: SessionInspectorStatus;
  agentGraph: {
    parentSessionId?: string;
    suggestedParentId?: string;
    linkSource?: 'path' | 'manual';
    childCount: number;
    suggestedChildCount: number;
    childRollup?: {
      sources: Record<string, number>;
      tokenTotal?: number;
      estimatedCostUsd?: number;
    };
  };
  llm: {
    auditRecordCount: number;
    lastAuditAt?: string;
    callers: LlmAuditCaller[];
    lastError?: string;
    promptVersion?: string;
    resolvedSummaryConfig?: {
      preset?: string;
      maxTokens: number;
      temperature: number;
      sampleFirst: number;
      sampleLast: number;
      truncateChars: number;
    };
    trigger?: LlmAuditTrigger;
  };
  resume: ResumeInspection;
  cost: {
    inputTokens?: number;
    outputTokens?: number;
    cacheReadTokens?: number;
    cacheCreationTokens?: number;
    estimatedCostUsd?: number;
    source: 'engram_pricing' | 'provider_reported' | 'unknown';
    pricedCoverage?: number;
    unknownModelCount?: number;
    warning?: string;
  };
}

export interface BuildSessionInspectorOptions {
  now?: Date;
  resumeResolver?: (cmd: string) => string | null;
}

export function deriveSessionStatus(input: {
  endTime?: string | null;
  messageCount: number;
}): SessionInspectorStatus {
  const tags: string[] = [];
  if (input.endTime) {
    tags.push('has_end_time');
    return {
      label: 'done',
      confidence: 'high',
      source: 'rule',
      basisTags: tags,
    };
  }
  if (input.messageCount === 0) {
    tags.push('no_messages');
    return {
      label: 'unknown',
      confidence: 'low',
      source: 'rule',
      basisTags: tags,
    };
  }
  return {
    label: 'unknown',
    confidence: 'low',
    source: 'fallback',
    basisTags: tags,
  };
}

export { buildResumeInspection };

const EMBEDDING_CALLERS = new Set([
  'embedding',
  'embeddings',
  'semantic_index',
  'memory',
]);

function normalizeCaller(raw: string): LlmAuditCaller | null {
  if (raw === 'summary') return 'summary';
  if (raw === 'title') return 'title';
  if (EMBEDDING_CALLERS.has(raw)) return 'embedding';
  return null;
}

function normalizeTrigger(raw: unknown): LlmAuditTrigger | undefined {
  if (raw === 'manual' || raw === 'auto' || raw === 'indexing') return raw;
  if (raw === undefined || raw === null) return undefined;
  return 'unknown';
}

interface AuditRowSlim {
  ts: string;
  caller: string;
  error: string | null;
  meta: string | null;
}

interface AuditCorrelation {
  count: number;
  lastAuditAt?: string;
  callers: LlmAuditCaller[];
  lastError?: string;
  promptVersion?: string;
  resolvedSummaryConfig?: SessionInspector['llm']['resolvedSummaryConfig'];
  trigger?: LlmAuditTrigger;
}

function readAuditCorrelation(
  db: Database,
  sessionId: string,
): AuditCorrelation {
  const rows = db
    .getRawDb()
    .prepare(
      `SELECT ts, caller, error, meta FROM ai_audit_log
       WHERE session_id = ? ORDER BY ts DESC`,
    )
    .all(sessionId) as AuditRowSlim[];

  const result: AuditCorrelation = { count: rows.length, callers: [] };
  if (rows.length === 0) return result;

  const callerSet = new Set<LlmAuditCaller>();
  let latestSummaryMeta: Record<string, unknown> | null = null;

  for (const row of rows) {
    const normalized = normalizeCaller(row.caller);
    if (normalized) callerSet.add(normalized);

    if (!result.lastAuditAt) result.lastAuditAt = row.ts;
    if (!result.lastError && row.error) result.lastError = row.error;

    if (row.caller === 'summary' && !latestSummaryMeta && row.meta) {
      try {
        latestSummaryMeta = JSON.parse(row.meta) as Record<string, unknown>;
      } catch {
        // ignore unparseable meta
      }
    }
  }

  result.callers = [...callerSet].sort();

  if (latestSummaryMeta) {
    const trig = normalizeTrigger(latestSummaryMeta.trigger);
    if (trig) result.trigger = trig;
    const resolved = latestSummaryMeta.resolvedConfig as
      | Record<string, unknown>
      | undefined;
    if (resolved && typeof resolved === 'object') {
      const config: SessionInspector['llm']['resolvedSummaryConfig'] = {
        maxTokens: Number(resolved.maxTokens) || 0,
        temperature: Number(resolved.temperature) || 0,
        sampleFirst: Number(resolved.sampleFirst) || 0,
        sampleLast: Number(resolved.sampleLast) || 0,
        truncateChars: Number(resolved.truncateChars) || 0,
      };
      if (typeof resolved.preset === 'string') config.preset = resolved.preset;
      result.resolvedSummaryConfig = config;
    }
    if (typeof latestSummaryMeta.promptVersion === 'string') {
      result.promptVersion = latestSummaryMeta.promptVersion;
    }
  }

  return result;
}

function deriveTitleProvenance(input: {
  generatedTitle?: string;
  customName?: string;
  storedSummary?: string;
}): DerivedFieldProvenance {
  if (input.generatedTitle) return 'ai_audit';
  if (input.customName) return 'database';
  if (input.storedSummary) return 'database';
  return 'fallback';
}

function deriveParentLinkProvenance(input: {
  parentSessionId?: string;
  suggestedParentId?: string;
  linkSource?: 'path' | 'manual';
}): DerivedFieldProvenance {
  if (input.parentSessionId) {
    if (input.linkSource === 'path' || input.linkSource === 'manual') {
      return 'database';
    }
    return 'database';
  }
  if (input.suggestedParentId) return 'heuristic';
  return 'unknown';
}

function isAllowedTier(
  tier: string | undefined,
): SessionInspector['session']['tier'] {
  if (
    tier === 'skip' ||
    tier === 'lite' ||
    tier === 'normal' ||
    tier === 'premium'
  ) {
    return tier;
  }
  return undefined;
}

export function buildSessionInspector(
  db: Database,
  id: string,
  opts: BuildSessionInspectorOptions = {},
): SessionInspector | null {
  const session = db.getSessionInspectorSession(id);
  if (!session) return null;

  const cost = db.getSessionCost(id);
  const childCount = db.childCount([id]).get(id) ?? 0;
  const suggestedChildCount = db.suggestedChildCount([id]).get(id) ?? 0;

  let childRollup: SessionInspector['agentGraph']['childRollup'];
  if (childCount > 0) {
    const sources = db.getChildSourceBreakdown(id);
    const rollup = db.getChildCostRollup(id);
    childRollup = {
      sources,
      ...(rollup
        ? {
            tokenTotal: rollup.tokenTotal,
            estimatedCostUsd: rollup.estimatedCostUsd,
          }
        : {}),
    };
  }

  const audit = readAuditCorrelation(db, id);

  const resume = buildResumeInspection(
    session.source,
    id,
    session.cwd ?? '',
    opts.resumeResolver ? { resolveCommand: opts.resumeResolver } : undefined,
  );

  const status = deriveSessionStatus({
    endTime: session.endTime,
    messageCount: session.messageCount,
  });

  const titleProv = deriveTitleProvenance({
    generatedTitle: session.generatedTitle,
    customName: session.customName,
    storedSummary: session.summary,
  });

  const parentLinkProv = deriveParentLinkProvenance({
    parentSessionId: session.parentSessionId,
    suggestedParentId: session.suggestedParentId,
    linkSource: session.linkSource,
  });

  const sessionFacts: SessionInspector['session'] = {
    id: session.id,
    source: session.source,
    messageCount: session.messageCount,
  };
  if (session.project) sessionFacts.project = session.project;
  if (session.cwd) sessionFacts.cwd = session.cwd;
  if (session.model) sessionFacts.model = session.model;
  if (session.startTime) sessionFacts.startTime = session.startTime;
  if (session.endTime) sessionFacts.endTime = session.endTime;
  if (session.filePath) sessionFacts.filePath = session.filePath;
  const tier = isAllowedTier(session.tier);
  if (tier) sessionFacts.tier = tier;
  if (session.agentRole) sessionFacts.agentRole = session.agentRole;

  const summaries: SessionInspector['summaries'] = {
    provenance: {
      firstMessageSummary: 'unknown',
      storedSummary: session.summary ? 'adapter_first_message' : 'unknown',
      llmSummary: 'unknown',
      compactSummary: 'unknown',
    },
  };
  const displayTitle =
    session.customName ?? session.generatedTitle ?? session.summary;
  if (displayTitle) summaries.displayTitle = displayTitle;
  if (session.summary) summaries.storedSummary = session.summary;
  if (
    session.summaryMessageCount !== undefined &&
    session.summaryMessageCount !== null
  ) {
    summaries.summaryMessageCount = session.summaryMessageCount;
  }

  const agentGraph: SessionInspector['agentGraph'] = {
    childCount,
    suggestedChildCount,
  };
  if (session.parentSessionId)
    agentGraph.parentSessionId = session.parentSessionId;
  if (session.suggestedParentId)
    agentGraph.suggestedParentId = session.suggestedParentId;
  if (session.linkSource) agentGraph.linkSource = session.linkSource;
  if (childRollup) agentGraph.childRollup = childRollup;

  const llm: SessionInspector['llm'] = {
    auditRecordCount: audit.count,
    callers: audit.callers,
  };
  if (audit.lastAuditAt) llm.lastAuditAt = audit.lastAuditAt;
  if (audit.lastError) llm.lastError = audit.lastError;
  if (audit.promptVersion) llm.promptVersion = audit.promptVersion;
  if (audit.resolvedSummaryConfig)
    llm.resolvedSummaryConfig = audit.resolvedSummaryConfig;
  if (audit.trigger) llm.trigger = audit.trigger;

  const costFacts: SessionInspector['cost'] = cost
    ? {
        inputTokens: cost.inputTokens,
        outputTokens: cost.outputTokens,
        cacheReadTokens: cost.cacheReadTokens,
        cacheCreationTokens: cost.cacheCreationTokens,
        estimatedCostUsd: cost.costUsd,
        source: 'engram_pricing',
      }
    : {
        source: 'unknown',
        warning: 'No cost data available',
      };

  return {
    session: sessionFacts,
    provenance: {
      transcript: session.filePath ? 'local_file' : 'database_snapshot',
      title: titleProv,
      cost: cost ? 'database' : 'unknown',
      parentLink: parentLinkProv,
    },
    summaries,
    status,
    agentGraph,
    llm,
    resume,
    cost: costFacts,
  };
}
