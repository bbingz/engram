import { execFileSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';

const repoRoot = resolve(import.meta.dirname, '../..');
const hasXcodegen = (() => {
  try {
    execFileSync('bash', ['-c', 'command -v xcodegen'], {
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

describe.skipIf(!hasXcodegen)('Swift module boundary scripts', () => {
  it('enforces app, MCP, and CLI cannot depend on EngramCoreWrite', () => {
    const script = resolve(
      repoRoot,
      'scripts/check-swift-module-boundaries.sh',
    );
    expect(existsSync(script)).toBe(true);
    expect(runScript(script)).toContain('swift module boundaries ok');
  });
});
