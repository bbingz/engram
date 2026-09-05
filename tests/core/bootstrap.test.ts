import { existsSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { createMCPDeps } from '../../src/core/bootstrap.js';

describe('createMCPDeps', () => {
  const roots: string[] = [];
  let home: string;
  let dataDir: string;

  beforeEach(() => {
    const root = mkdtempSync(join(tmpdir(), 'engram-bootstrap-'));
    roots.push(root);
    home = join(root, 'home');
    dataDir = join(root, 'data');
    // docs/invariants.md #6: every bootstrap test gets a closed temporary home.
    vi.stubEnv('HOME', home);
    vi.stubEnv('CFFIXED_USER_HOME', home);
    vi.stubEnv('TMPDIR', root);
    vi.stubEnv('ENGRAM_DIR', dataDir);
  });

  afterEach(() => {
    vi.unstubAllEnvs();
    for (const root of roots.splice(0)) {
      rmSync(root, { recursive: true, force: true });
    }
  });

  it('uses the injected Engram directory for in-memory dependencies (repro)', () => {
    const deps = createMCPDeps({ dbPath: ':memory:' });
    expect(existsSync(join(dataDir, 'cache', 'antigravity'))).toBe(true);
    expect(existsSync(join(dataDir, 'cache', 'windsurf'))).toBe(true);
    expect(existsSync(join(home, '.engram'))).toBe(false);
    deps.db.close();
  });

  it('runs every bootstrap case inside a hermetic home (repro)', () => {
    expect(process.env.HOME).toMatch(/engram-bootstrap-/);
    expect(process.env.ENGRAM_DIR).toMatch(/engram-bootstrap-/);
  });

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
