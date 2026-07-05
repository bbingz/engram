import { describe, expect, it } from 'vitest';
import { createMCPDeps } from '../../src/core/bootstrap.js';

describe('createMCPDeps', () => {
  it('returns all required fields with in-memory db', () => {
    const deps = createMCPDeps({ dbPath: ':memory:' });
    expect(deps.db).toBeDefined();
    expect(deps.adapters.length).toBeGreaterThan(0);
    expect(deps.adapterMap).toBeDefined();
    expect(deps.settings).toBeDefined();
    expect(deps.audit).toBeDefined();
    expect(deps.tracer).toBeDefined();
    expect(deps.traceWriter).toBeDefined();
    expect(deps.indexer).toBeDefined();
    expect(deps.indexJobRunner).toBeDefined();
    expect('vecDeps' in deps).toBe(true);
    deps.db.close();
  });

  it('adapters include known sources', () => {
    const deps = createMCPDeps({ dbPath: ':memory:' });
    const names = deps.adapters.map((a) => a.name);
    expect(names).toContain('claude-code');
    expect(names).toContain('codex');
    expect(names).toContain('gemini-cli');
    expect(names).toContain('qoder');
    expect(names).toContain('commandcode');
    deps.db.close();
  });
});
