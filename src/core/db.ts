// src/core/db.ts — ESM compatibility shim
// All logic lives in src/core/db/*.ts. This file preserves the import path
// so that `import { Database } from '../core/db.js'` continues to work.

export { Database } from './db/database.js';
export { containsCJK } from './db/fts-repo.js';
export type { InsightRow } from './db/insight-repo.js';
export { FTS_VERSION, SCHEMA_VERSION } from './db/migration.js';
export { buildTierFilter, isTierHidden } from './db/session-repo.js';
export type {
  CostSummaryRow,
  FileActivityRow,
  FtsSearchResult,
  ListSessionsOptions,
  NoiseFilter,
  SearchFilters,
  StatsGroup,
  ToolAnalyticsRow,
} from './db/types.js';
