import { execFileSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';

const repoRoot = resolve(import.meta.dirname, '../..');
const hasRg = (() => {
  try {
    execFileSync('bash', ['-c', 'command -v rg'], {
      stdio: 'ignore',
    });
    return true;
  } catch {
    return false;
  }
})();

function runScript(path: string): string {
  return execFileSync('bash', [path], {
    cwd: repoRoot,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
  });
}

describe.skipIf(!hasRg)('Swift product boundary scripts', () => {
  it('keeps app, MCP, and CLI direct GRDB writes out of product surfaces', () => {
    const script = resolve(
      repoRoot,
      'scripts/check-app-mcp-cli-direct-writes.sh',
    );
    expect(existsSync(script)).toBe(true);
    expect(runScript(script)).toContain('direct write scan ok');
  });

  it('keeps indexing test doubles out of product target sources', () => {
    const script = resolve(
      repoRoot,
      'scripts/check-indexing-test-double-boundaries.sh',
    );
    expect(existsSync(script)).toBe(true);
    expect(runScript(script)).toContain('indexing test double boundaries ok');
  });

  it('keeps migrated Stage 3 surfaces free of legacy daemon transport', () => {
    const script = resolve(repoRoot, 'scripts/check-stage3-daemon-cutover.sh');
    expect(existsSync(script)).toBe(true);
    expect(runScript(script)).toContain('Stage 3 daemon cutover scan ok');
  });
});
