import { existsSync, readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';

const repoRoot = resolve(import.meta.dirname, '../..');

const deletedSourcePaths = [
  'src/web.ts',
  'src/index.ts',
  'src/daemon.ts',
  'src/web/routes',
  'src/web/views.ts',
  'src/core/lifecycle.ts',
  'src/core/daemon-startup.ts',
  'src/core/auto-summary.ts',
  'src/core/alert-rules.ts',
  'src/core/mock-data.ts',
  'src/core/daemon-client.ts',
  'src/core/git-probe.ts',
  'src/core/watcher.ts',
  'src/core/sync.ts',
  'src/cli/resume.ts',
];

const deletedTestPaths = [
  'tests/web',
  'tests/core/daemon-startup.test.ts',
  'tests/core/lifecycle.test.ts',
  'tests/core/auto-summary.test.ts',
  'tests/core/alert-rules.test.ts',
  'tests/core/mock-data.test.ts',
  'tests/core/daemon-client.test.ts',
  'tests/core/mcp-write-policy-wiring.test.ts',
  'tests/core/sync.test.ts',
  'tests/cli/resume.test.ts',
];

describe('feature-cut TS dev server surface', () => {
  it('keeps the deleted legacy HTTP, MCP, and daemon entrypoints out of the active tree', () => {
    for (const path of [...deletedSourcePaths, ...deletedTestPaths]) {
      expect(existsSync(resolve(repoRoot, path)), path).toBe(false);
    }
  });

  it('does not keep active package, knip, or CLI references to deleted entrypoints', () => {
    const packageJson = JSON.parse(
      readFileSync(resolve(repoRoot, 'package.json'), 'utf8'),
    ) as { scripts?: Record<string, string> };
    const knipJson = JSON.parse(
      readFileSync(resolve(repoRoot, 'knip.json'), 'utf8'),
    ) as { entry?: string[]; ignoreIssues?: Record<string, unknown> };
    const cliSource = readFileSync(
      resolve(repoRoot, 'src/cli/index.ts'),
      'utf8',
    );

    expect(packageJson.scripts?.dev).toBeUndefined();
    expect(knipJson.entry).not.toEqual(
      expect.arrayContaining([
        'src/index.ts',
        'src/daemon.ts',
        'src/cli/resume.ts',
      ]),
    );
    expect(knipJson.ignoreIssues).not.toHaveProperty(
      'src/core/daemon-client.ts',
    );
    expect(cliSource).not.toContain('../index.js');
    expect(cliSource).not.toContain('./resume.js');
  });
});
