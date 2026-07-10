import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { describe, expect, it } from 'vitest';

const repoRoot = resolve(import.meta.dirname, '../..');
const script = resolve(repoRoot, 'scripts/check-invariants-ledger.sh');
const defaultGates = resolve(repoRoot, 'scripts/invariant-gates.json');
const checkedPathPrefixes = [
  'macos/',
  'src/',
  'scripts/',
  'tests/',
  'test-fixtures/',
  'docs/',
  '.github/',
];
const checkedRootPaths = ['AGENTS.md', 'CLAUDE.md'];

function runScript(
  args: string[] = [],
  cwd = repoRoot,
): { stdout: string; stderr: string; status: number | null } {
  try {
    const stdout = execFileSync('bash', [script, ...args], {
      cwd,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    return { stdout, stderr: '', status: 0 };
  } catch (error) {
    const err = error as {
      status?: number | null;
      stdout?: string;
      stderr?: string;
    };
    return {
      stdout: err.stdout ?? '',
      stderr: err.stderr ?? '',
      status: err.status ?? 1,
    };
  }
}

function writeMinimalLedger(dir: string, extraLines: string[] = []): string {
  const ledger = join(dir, 'invariants.md');
  writeFileSync(
    ledger,
    [
      '# Invariants',
      '',
      '## 1. Fixture',
      '',
      '- **Statement** - Fixture invariant.',
      '- **Enforced by** - `scripts/check-invariants-ledger.sh`.',
      '- **Verified by** - `tests/scripts/invariants-ledger.test.ts`.',
      ...extraLines,
    ].join('\n'),
    'utf8',
  );
  return ledger;
}

function writeGates(
  dir: string,
  registry: Record<string, unknown>,
): string {
  const path = join(dir, 'invariant-gates.json');
  writeFileSync(path, `${JSON.stringify(registry, null, 2)}\n`, 'utf8');
  return path;
}

describe('invariants ledger gate script', () => {
  it('passes for the repo invariants ledger with allowlisted gates', () => {
    const result = runScript();
    expect(result.status).toBe(0);
    expect(result.stdout).toContain('invariants ledger ok');
  });

  it('passes under stock macOS /bin/bash with the valid registry', () => {
    // L09 portability: the runner must not require bash 4+ features (mapfile).
    const pathEnv = `/opt/homebrew/bin:/usr/local/bin:${process.env.PATH ?? ''}`;
    const stdout = execFileSync('/bin/bash', [script], {
      cwd: repoRoot,
      encoding: 'utf8',
      env: { ...process.env, PATH: pathEnv },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    expect(stdout).toContain('invariants ledger ok');
  });

  it('keeps enforced and verified anchors inside the checked path set', () => {
    const ledger = readFileSync(
      resolve(repoRoot, 'docs/invariants.md'),
      'utf8',
    );
    const anchorLines = ledger
      .split('\n')
      .filter((line) => /^- \*\*(Enforced by|Verified by)\*\*/.test(line));
    const uncheckedAnchors = anchorLines
      .flatMap((line) =>
        Array.from(line.matchAll(/`([^`]+)`/g), (match) => match[1].trim()),
      )
      .filter((token) => {
        const candidate = token.replace(/:\d+$/, '');
        return (
          !checkedPathPrefixes.some((prefix) => candidate.startsWith(prefix)) &&
          !checkedRootPaths.includes(candidate)
        );
      });

    expect(uncheckedAnchors).toEqual([]);
  });

  it('rejects backticked repo-relative paths that do not exist', () => {
    const tempDir = mkdtempSync(resolve(tmpdir(), 'engram-invariants-ledger-'));
    const ledger = resolve(tempDir, 'invariants.md');
    writeFileSync(
      ledger,
      [
        '# Invariants',
        '',
        '- **Statement** - Missing-path sentinel.',
        '- **Enforced by** - `docs/does-not-exist.md`.',
        '- **Verified by** - `tests/scripts/invariants-ledger.test.ts`.',
      ].join('\n'),
    );

    const result = runScript([ledger, defaultGates]);
    expect(result.status).not.toBe(0);
    expect(`${result.stdout}${result.stderr}`).toMatch(
      /docs\/does-not-exist\.md/,
    );
  });

  it('strips line suffixes and reports every missing path', () => {
    const tempDir = mkdtempSync(resolve(tmpdir(), 'engram-invariants-ledger-'));
    const ledger = resolve(tempDir, 'invariants.md');
    writeFileSync(
      ledger,
      [
        '# Invariants',
        '',
        '- **Enforced by** - `docs/invariants.md:1`, `CLAUDE.md:1`.',
        '- **Verified by** - `docs/missing-one.md`, `tests/missing-two.ts`.',
      ].join('\n'),
    );

    const result = runScript([ledger, defaultGates]);
    expect(result.status).not.toBe(0);
    expect(`${result.stdout}${result.stderr}`).toMatch(
      /docs\/missing-one\.md[\s\S]*tests\/missing-two\.ts/,
    );
  });

  it('fails when the gates registry is missing', () => {
    const tempDir = mkdtempSync(resolve(tmpdir(), 'engram-invariants-gates-'));
    const ledger = writeMinimalLedger(tempDir);
    const missingGates = join(tempDir, 'missing-gates.json');
    const result = runScript([ledger, missingGates]);
    expect(result.status).not.toBe(0);
    expect(`${result.stdout}${result.stderr}`).toMatch(
      /invariant gates registry not found/,
    );
  });

  it('fails when the gates registry is invalid JSON', () => {
    const tempDir = mkdtempSync(resolve(tmpdir(), 'engram-invariants-gates-'));
    const ledger = writeMinimalLedger(tempDir);
    const gates = join(tempDir, 'invariant-gates.json');
    writeFileSync(gates, '{not-json', 'utf8');
    const result = runScript([ledger, gates]);
    expect(result.status).not.toBe(0);
    expect(`${result.stdout}${result.stderr}`).toMatch(
      /invalid invariant gates registry JSON/,
    );
  });

  it('fails when an invariant references an unknown gate id', () => {
    const tempDir = mkdtempSync(resolve(tmpdir(), 'engram-invariants-gates-'));
    // Point ledger paths at real repo files via absolute-style relative paths
    // checked under ROOT_DIR of the script invocation (repo root).
    const ledger = writeMinimalLedger(tempDir);
    const gates = writeGates(tempDir, {
      version: 1,
      gates: {
        'ledger-paths': { type: 'ledger-paths' },
      },
      invariants: {
        '1': ['ledger-paths', 'not-a-real-gate'],
      },
    });
    const result = runScript([ledger, gates]);
    expect(result.status).not.toBe(0);
    expect(`${result.stdout}${result.stderr}`).toMatch(
      /unknown gate id ['"]not-a-real-gate['"]/,
    );
  });

  it('fails a present-but-behaviorally-invalid fixture even when paths exist (L09)', () => {
    // Old path-existence-only gate would pass: every backticked path exists.
    // New gate must still fail because the allowlisted behavioral script exits 1.
    const tempDir = mkdtempSync(resolve(tmpdir(), 'engram-invariants-beh-'));
    const ledger = writeMinimalLedger(tempDir);
    const gates = writeGates(tempDir, {
      version: 1,
      gates: {
        'ledger-paths': { type: 'ledger-paths' },
        'failing-behavior': {
          type: 'argv',
          argv: ['bash', 'scripts/test-support/always-fail-invariant-gate.sh'],
        },
      },
      invariants: {
        '1': ['ledger-paths', 'failing-behavior'],
      },
    });

    const result = runScript([ledger, gates]);
    expect(result.status).not.toBe(0);
    expect(`${result.stdout}${result.stderr}`).toMatch(
      /invariant gate failed: failing-behavior|behaviorally invalid fixture/,
    );
  });

  it('rejects gate argv that escapes the scripts/ allowlist (no arbitrary shell)', () => {
    const tempDir = mkdtempSync(resolve(tmpdir(), 'engram-invariants-escape-'));
    const ledger = writeMinimalLedger(tempDir);
    const gates = writeGates(tempDir, {
      version: 1,
      gates: {
        'ledger-paths': { type: 'ledger-paths' },
        evil: {
          type: 'argv',
          argv: ['bash', '-c', 'echo pwned'],
        },
      },
      invariants: {
        '1': ['ledger-paths', 'evil'],
      },
    });
    const result = runScript([ledger, gates]);
    expect(result.status).not.toBe(0);
    expect(`${result.stdout}${result.stderr}`).toMatch(
      /exact argv schema|must be exactly \["bash"|invalid argv/,
    );
  });

  /// L09 bypass repro: a decoy scripts/ token must not authorize bash -c payloads.
  it('rejects bash -c smuggled beside a decoy scripts/ token and never executes it (repro)', () => {
    const marker = 'ARGV_BYPASS_MARKER';
    const tempDir = mkdtempSync(resolve(tmpdir(), 'engram-invariants-bypass-'));
    const ledger = writeMinimalLedger(tempDir);
    const gates = writeGates(tempDir, {
      version: 1,
      gates: {
        'ledger-paths': { type: 'ledger-paths' },
        bypass: {
          type: 'argv',
          // Previous validator only required *some* token under scripts/, so this
          // malicious argv executed the -c payload and still exited 0.
          argv: [
            'bash',
            '-c',
            `printf ${marker}`,
            'scripts/check-app-mcp-cli-direct-writes.sh',
          ],
        },
      },
      invariants: {
        '1': ['ledger-paths', 'bypass'],
      },
    });

    const result = runScript([ledger, gates]);
    const combined = `${result.stdout}${result.stderr}`;
    expect(result.status).not.toBe(0);
    expect(combined).not.toContain(marker);
    expect(combined).not.toMatch(/invariants ledger ok/);
    expect(combined).toMatch(
      /exact argv schema|must be exactly \["bash"|invalid argv/,
    );
  });

  it('loads the default registry and never shells markdown content', () => {
    const registry = JSON.parse(readFileSync(defaultGates, 'utf8')) as {
      gates: Record<string, { type?: string; argv?: string[] }>;
      invariants: Record<string, string[]>;
    };
    expect(Object.keys(registry.gates).length).toBeGreaterThan(0);
    expect(Object.keys(registry.invariants).length).toBeGreaterThan(0);
    for (const [gateId, spec] of Object.entries(registry.gates)) {
      if (spec.type === 'ledger-paths') continue;
      expect(spec.type).toBe('argv');
      expect(spec.argv).toHaveLength(2);
      expect(spec.argv?.[0]).toBe('bash');
      expect(spec.argv?.[1]).toMatch(/^scripts\/[A-Za-z0-9._/-]+\.sh$/);
      expect(spec.argv?.[1]?.includes('..')).toBe(false);
      expect(gateId).not.toMatch(/[`$]/);
    }
    // Markdown is not an execution source: registry maps IDs to gate IDs only.
    for (const gateIds of Object.values(registry.invariants)) {
      for (const gateId of gateIds) {
        expect(registry.gates[gateId]).toBeDefined();
      }
    }
  });
});
