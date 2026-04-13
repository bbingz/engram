// src/core/db.ts — ESM compatibility shim
// All logic lives in src/core/db/*.ts. This file preserves the import path
// so that `import { Database } from '../core/db.js'` continues to work.

export { Database } from './db/database.js';
export { containsCJK } from './db/fts-repo.js';
export { SCHEMA_VERSION } from './db/migration.js';
export { isTierHidden } from './db/session-repo.js';
export type {
  FileActivityRow,
  ListSessionsOptions,
  SearchFilters,
} from './db/types.js';
