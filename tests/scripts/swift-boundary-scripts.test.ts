import { execFileSync } from 'node:child_process';
import { existsSync, mkdtempSync, rmSync, symlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';

const repoRoot = resolve(import.meta.dirname, '../..');
const xcodegenPath = (() => {
  try {
    return execFileSync('bash', ['-c', 'command -v xcodegen'], {
      encoding: 'utf8',
    }).trim();
  } catch {
    return undefined;
  }
})();

function runScript(path: string, env = process.env): string {
  return execFileSync('bash', [path], {
    cwd: repoRoot,
    encoding: 'utf8',
    env,
    stdio: ['ignore', 'pipe', 'pipe'],
  });
}

describe.skipIf(!xcodegenPath)('Swift module boundary scripts', () => {
  it('enforces app, MCP, and CLI cannot depend on EngramCoreWrite', () => {
    const script = resolve(
      repoRoot,
      'scripts/check-swift-module-boundaries.sh',
    );
    expect(existsSync(script)).toBe(true);
    expect(runScript(script)).toContain('swift module boundaries ok');
  });

  it('falls back to system grep when ripgrep is unavailable', () => {
    const toolBin = mkdtempSync(resolve(tmpdir(), 'engram-boundary-tools-'));
    try {
      symlinkSync(process.execPath, resolve(toolBin, 'node'));
      symlinkSync(xcodegenPath!, resolve(toolBin, 'xcodegen'));
      const path = `${toolBin}:/usr/bin:/bin:/usr/sbin:/sbin`;

      expect(
        runScript(
          resolve(repoRoot, 'scripts/check-swift-module-boundaries.sh'),
          {
            ...process.env,
            PATH: path,
          },
        ),
      ).toContain('swift module boundaries ok');
    } finally {
      rmSync(toolBin, { recursive: true, force: true });
    }
  });
});
