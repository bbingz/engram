// tests/tools/tool-errors.test.ts
// Tests error/edge-case behavior of MCP tool handler functions.
// Verifies handlers return graceful results (empty arrays, zero counts)
// rather than throwing unhandled exceptions on edge case inputs.

import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { Database } from '../../src/core/db.js';
import { handleFileActivity } from '../../src/tools/file_activity.js';
import { handleGetCosts } from '../../src/tools/get_costs.js';
import { handleLintConfig } from '../../src/tools/lint_config.js';
import { handleListSessions } from '../../src/tools/list_sessions.js';
import { handleProjectTimeline } from '../../src/tools/project_timeline.js';
import { handleSearch } from '../../src/tools/search.js';
import { handleStats } from '../../src/tools/stats.js';
import { handleToolAnalytics } from '../../src/tools/tool_analytics.js';

let db: Database;
let tmpDir: string;

beforeEach(() => {
  tmpDir = mkdtempSync(join(tmpdir(), 'tool-errors-test-'));
  db = new Database(join(tmpDir, 'test.sqlite'));
});

afterEach(() => {
  db.close();
  rmSync(tmpDir, { recursive: true });
});

describe('handleListSessions with no data', () => {
  it('returns empty sessions array without crashing', async () => {
    const result = await handleListSessions(db, {});
    expect(result.sessions).toBeDefined();
    expect(Array.isArray(result.sessions)).toBe(true);
    expect(result.sessions).toHaveLength(0);
  });
});

describe('handleSearch edge cases', () => {
  it('returns empty results for empty string query', async () => {
    const result = await handleSearch(db, { query: '' });
    expect(result.results).toBeDefined();
    expect(Array.isArray(result.results)).toBe(true);
    expect(result.results).toHaveLength(0);
  });

  it('does not crash with a very long query (>10000 chars)', async () => {
    const longQuery = 'a'.repeat(10001);
    const result = await handleSearch(db, { query: longQuery });
    expect(result.results).toBeDefined();
    expect(Array.isArray(result.results)).toBe(true);
  });

  it('returns empty results when no sessions are indexed', async () => {
    const result = await handleSearch(db, { query: 'something' });
    expect(result.results).toHaveLength(0);
  });
});

describe('handleStats with empty database', () => {
  it('returns zero totalSessions and empty groups', async () => {
    const result = await handleStats(db, {});
    expect(result.totalSessions).toBe(0);
    expect(Array.isArray(result.groups)).toBe(true);
    expect(result.groups).toHaveLength(0);
  });

  it('returns valid structure when grouping by project on empty db', async () => {
    const result = await handleStats(db, { group_by: 'project' });
    expect(result.groupBy).toBe('project');
    expect(result.totalSessions).toBe(0);
    expect(result.groups).toHaveLength(0);
  });
});

describe('handleGetCosts with no cost data', () => {
  it('returns zero totals and empty breakdown', () => {
    const result = handleGetCosts(db, {});
    expect(result.totalCostUsd).toBe(0);
    expect(result.totalInputTokens).toBe(0);
    expect(result.totalOutputTokens).toBe(0);
    expect(Array.isArray(result.breakdown)).toBe(true);
    expect(result.breakdown).toHaveLength(0);
  });
});

describe('handleToolAnalytics with no data', () => {
  it('returns zero totalCalls and empty tools list', () => {
    const result = handleToolAnalytics(db, {});
    expect(result.totalCalls).toBe(0);
    expect(result.groupCount).toBe(0);
    expect(Array.isArray(result.tools)).toBe(true);
    expect(result.tools).toHaveLength(0);
  });
});

describe('handleProjectTimeline with nonexistent project', () => {
  it('returns empty timeline for unknown project', async () => {
    const result = await handleProjectTimeline(db, {
      project: 'nonexistent-project-xyz',
    });
    expect(result.total).toBe(0);
    expect(Array.isArray(result.timeline)).toBe(true);
    expect(result.timeline).toHaveLength(0);
    expect(result.project).toBe('nonexistent-project-xyz');
  });
});

describe('handleLintConfig with nonexistent cwd', () => {
  it('returns result object without crashing for missing directory', async () => {
    const result = await handleLintConfig({
      cwd: '/nonexistent/path/that/does/not/exist',
    });
    expect(result).toBeDefined();
    expect(Array.isArray(result.issues)).toBe(true);
    // No config files found → no issues from file parsing
    expect(result.issues).toHaveLength(0);
    expect(typeof result.score).toBe('number');
    expect(result.score).toBe(100);
  });
});

describe('handleFileActivity with no data', () => {
  it('returns empty files list and zero totalFiles', () => {
    const result = handleFileActivity(db, {});
    expect(result.totalFiles).toBe(0);
    expect(Array.isArray(result.files)).toBe(true);
    expect(result.files).toHaveLength(0);
  });

  it('does not crash when filtering by nonexistent project', () => {
    const result = handleFileActivity(db, { project: 'no-such-project' });
    expect(result.totalFiles).toBe(0);
    expect(result.files).toHaveLength(0);
  });
});
