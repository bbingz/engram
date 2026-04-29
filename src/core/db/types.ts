// src/core/db/types.ts — shared types for db modules
import type { SourceName } from '../../adapters/types.js';

export interface ListSessionsOptions {
  source?: SourceName;
  sources?: string[];
  project?: string;
  projects?: string[];
  origin?: string;
  origins?: string[];
  since?: string;
  until?: string;
  limit?: number;
  offset?: number;
  agents?: 'hide' | 'only'; // hide = exclude agents, only = agents only
  /** Include orphan (file-missing) sessions. Default: orphans are hidden. */
  includeOrphans?: boolean;
}

export interface FtsSearchResult {
  sessionId: string;
  snippet: string;
  rank: number;
}

export interface StatsGroup {
  key: string;
  sessionCount: number;
  messageCount: number;
  userMessageCount: number;
  assistantMessageCount: number;
  toolMessageCount: number;
}

export type NoiseFilter = 'all' | 'hide-skip' | 'hide-noise';

export interface SearchFilters {
  source?: string;
  project?: string;
  since?: string;
}

export interface FileActivityRow {
  file_path: string;
  action: string;
  total_count: number;
  session_count: number;
}

/** @public used in return types of exported tool handlers */
export interface CostSummaryRow {
  key: string;
  inputTokens: number;
  outputTokens: number;
  cacheReadTokens: number;
  cacheCreationTokens: number;
  costUsd: number;
  sessionCount: number;
}

/** @public used in return types of exported tool handlers */
export interface ToolAnalyticsRow {
  key: string;
  callCount: number;
  label?: string;
  toolCount?: number;
  sessionCount?: number;
}
