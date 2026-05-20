import { describe, expect, it } from 'vitest';
import { registerAiAuditRoutes } from '../../src/web/routes/ai-audit.js';
import { registerProjectAliasRoutes } from '../../src/web/routes/project-aliases.js';
import { registerStatsRoutes } from '../../src/web/routes/stats.js';
import { registerSyncRoutes } from '../../src/web/routes/sync.js';

describe('web route modules', () => {
  it('exposes AI audit routes from a dedicated module', () => {
    expect(registerAiAuditRoutes).toEqual(expect.any(Function));
  });

  it('exposes Project Alias routes from a dedicated module', () => {
    expect(registerProjectAliasRoutes).toEqual(expect.any(Function));
  });

  it('exposes Sync routes from a dedicated module', () => {
    expect(registerSyncRoutes).toEqual(expect.any(Function));
  });

  it('exposes Stats and analytics routes from a dedicated module', () => {
    expect(registerStatsRoutes).toEqual(expect.any(Function));
  });
});
