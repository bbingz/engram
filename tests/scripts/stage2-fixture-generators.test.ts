import { execFileSync } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, relative, resolve } from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import packageJson from '../../package.json' with { type: 'json' };

const repoRoot = resolve(import.meta.dirname, '../..');

function runScript(
  script: string,
  args: string[] = [],
  cwd = repoRoot,
): string {
  return execFileSync('./node_modules/.bin/tsx', [script, ...args], {
    cwd,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
  });
}

function snapshotFixtureFiles(root: string): Map<string, string> {
  const files = execFileSync('find', [root, '-type', 'f'], {
    encoding: 'utf8',
  })
    .trim()
    .split('\n')
    .filter(Boolean)
    .sort();
  return new Map(
    files.map((file) => [relative(root, file), readFileSync(file, 'utf8')]),
  );
}

describe('stage2 Node parity fixture generators', () => {
  let tmp = '';

  afterEach(() => {
    if (tmp) rmSync(tmp, { recursive: true, force: true });
  });

  it('registers package scripts for all Stage 2 fixture gates', () => {
    expect(packageJson.scripts['generate:adapter-parity-fixtures']).toBe(
      'tsx scripts/gen-adapter-parity-fixtures.ts',
    );
    expect(packageJson.scripts['check:adapter-parity-fixtures']).toBe(
      'tsx scripts/check-adapter-parity-fixtures.ts',
    );
    expect(packageJson.scripts['generate:parent-detection-fixtures']).toBe(
      'tsx scripts/gen-parent-detection-fixtures.ts',
    );
    expect(packageJson.scripts['generate:indexer-parity-fixtures']).toBe(
      'tsx scripts/gen-indexer-parity-fixtures.ts',
    );
  });

  it('generates deterministic adapter parity fixtures with required fields', () => {
    tmp = mkdtempSync(join(tmpdir(), 'engram-adapter-parity-test-'));
    const fixtureRoot = join(tmp, 'adapter-parity');

    runScript('scripts/gen-adapter-parity-fixtures.ts', ['--out', fixtureRoot]);
    const first = snapshotFixtureFiles(fixtureRoot);
    runScript('scripts/gen-adapter-parity-fixtures.ts', ['--out', fixtureRoot]);
    expect(snapshotFixtureFiles(fixtureRoot)).toEqual(first);

    const expectedSources = [
      'antigravity',
      'claude-code',
      'cline',
      'codex',
      'copilot',
      'cursor',
      'gemini-cli',
      'iflow',
      'kimi',
      'opencode',
      'qwen',
      'vscode',
      'windsurf',
    ];
    for (const source of expectedSources) {
      const expectedPath = join(fixtureRoot, source, 'success.expected.json');
      expect(existsSync(expectedPath), source).toBe(true);
      const fixture = JSON.parse(readFileSync(expectedPath, 'utf8'));
      expect(fixture.source).toBe(source);
      expect(fixture.inputPath).toBeTruthy();
      expect(fixture.locator).toBeTruthy();
      expect(fixture.sessionInfo).toBeTruthy();
      expect(Array.isArray(fixture.messages)).toBe(true);
      expect(Array.isArray(fixture.toolCalls)).toBe(true);
      expect(fixture.usageTotals).toMatchObject({
        cacheCreationTokens: expect.any(Number),
        cacheReadTokens: expect.any(Number),
        inputTokens: expect.any(Number),
        outputTokens: expect.any(Number),
      });
      expect(fixture.fileToolCounts).toBeTruthy();
      expect(fixture.projectFields).toBeTruthy();
      expect(fixture.insightFields).toBeTruthy();
      expect(fixture.searchIndexFields).toBeTruthy();
      expect(fixture.statsFields).toBeTruthy();
      expect(fixture.failure).toBeNull();
      expect(fixture.nodeVersion).toMatch(/^v\d+\./);
      expect(fixture.generatedAtCommit).toBeTruthy();
    }
  }, 60_000);

  it('checks adapter parity fixtures for malformed coverage and file size', () => {
    tmp = mkdtempSync(join(tmpdir(), 'engram-adapter-parity-check-test-'));
    const fixtureRoot = join(tmp, 'adapter-parity');
    runScript('scripts/gen-adapter-parity-fixtures.ts', ['--out', fixtureRoot]);

    const output = runScript('scripts/check-adapter-parity-fixtures.ts', [
      '--fixture-root',
      fixtureRoot,
    ]);
    expect(output).toContain('adapter parity fixtures ok');

    const malformedManifest = join(
      fixtureRoot,
      '..',
      'adapter-malformed',
      'manifest.json',
    );
    rmSync(malformedManifest);
    expect(() =>
      runScript('scripts/check-adapter-parity-fixtures.ts', [
        '--fixture-root',
        fixtureRoot,
      ]),
    ).toThrow(/missing malformed manifest/);
  }, 60_000);

  it('generates parent detection and indexer fixtures deterministically', () => {
    tmp = mkdtempSync(join(tmpdir(), 'engram-stage2-fixture-test-'));
    const parentOut = join(tmp, 'parent-detection');
    const indexerOut = join(tmp, 'indexer-parity');

    runScript('scripts/gen-parent-detection-fixtures.ts', ['--out', parentOut]);
    runScript('scripts/gen-indexer-parity-fixtures.ts', ['--out', indexerOut]);
    const firstParent = snapshotFixtureFiles(parentOut);
    const firstIndexer = snapshotFixtureFiles(indexerOut);

    runScript('scripts/gen-parent-detection-fixtures.ts', ['--out', parentOut]);
    runScript('scripts/gen-indexer-parity-fixtures.ts', ['--out', indexerOut]);

    expect(snapshotFixtureFiles(parentOut)).toEqual(firstParent);
    expect(snapshotFixtureFiles(indexerOut)).toEqual(firstIndexer);

    const detection = JSON.parse(
      readFileSync(join(parentOut, 'detection-version.json'), 'utf8'),
    );
    expect(detection.detectionVersion).toBe(4);
    expect(detection.dispatchCases).toContainEqual({
      input: 'Review this repository implementation',
      isDispatch: true,
    });

    const checksums = JSON.parse(
      readFileSync(join(indexerOut, 'expected-db-checksums.json'), 'utf8'),
    );
    expect(checksums.tables.sessions.count).toBeGreaterThan(0);
    expect(checksums.tables.session_costs.sha256).toMatch(/^[0-9a-f]{64}$/);
    expect(checksums.tables.session_index_jobs.sha256).toMatch(
      /^[0-9a-f]{64}$/,
    );
  }, 60_000);
});
