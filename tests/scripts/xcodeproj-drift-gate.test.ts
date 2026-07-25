import { execFileSync } from 'node:child_process';
import { chmodSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';

const repoRoot = resolve(import.meta.dirname, '../..');
const script = resolve(repoRoot, 'scripts/check-xcodeproj-drift.sh');
const pbxproj = resolve(repoRoot, 'macos/Engram.xcodeproj/project.pbxproj');

function runScript(env: Record<string, string>): {
  status: number;
  stdout: string;
  stderr: string;
} {
  try {
    const stdout = execFileSync('bash', [script], {
      cwd: repoRoot,
      encoding: 'utf8',
      env: {
        ...process.env,
        XDG_CACHE_HOME: mkdtempSync(resolve(tmpdir(), 'engram-xg-')),
        ...env,
      },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    return { status: 0, stdout, stderr: '' };
  } catch (error) {
    const e = error as { status: number; stdout: string; stderr: string };
    return { status: e.status, stdout: e.stdout, stderr: e.stderr };
  }
}

function stub(body: string): string {
  const path = resolve(
    mkdtempSync(resolve(tmpdir(), 'engram-stub-')),
    'xcodegen',
  );
  writeFileSync(path, `#!/usr/bin/env bash\n${body}\n`);
  chmodSync(path, 0o755);
  return path;
}

const pbxprojIsClean = (() => {
  try {
    execFileSync('git', ['diff', '--quiet', '--', pbxproj], { cwd: repoRoot });
    return true;
  } catch {
    return false;
  }
})();

describe('xcodeproj drift gate', () => {
  it('refuses to run without the pinned xcodegen instead of trusting a local build', () => {
    const result = runScript({ XCODEGEN_BIN: '/nonexistent/xcodegen' });

    expect(result.status).toBe(1);
    expect(result.stderr).toContain('needs xcodegen');
    expect(result.stderr).toContain('CI rejects');
  });

  it.skipIf(!pbxprojIsClean)(
    'passes when regeneration leaves the project unchanged',
    () => {
      const result = runScript({ XCODEGEN_BIN: stub('exit 0') });

      expect(result.status).toBe(0);
      expect(result.stdout).toContain('xcodeproj drift ok');
    },
  );

  it.skipIf(!pbxprojIsClean)(
    'fails when regeneration changes the project',
    () => {
      const original = readFileSync(pbxproj, 'utf8');
      try {
        const result = runScript({
          XCODEGEN_BIN: stub(
            `printf '\\n// drift\\n' >> ${JSON.stringify(pbxproj)}`,
          ),
        });

        expect(result.status).toBe(1);
        expect(result.stderr).toContain(
          'their tests never compile and never run',
        );
        expect(result.stderr).toContain(
          'git add macos/Engram.xcodeproj/project.pbxproj',
        );
      } finally {
        writeFileSync(pbxproj, original);
      }
    },
  );
});
