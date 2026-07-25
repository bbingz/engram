import { execFileSync } from 'node:child_process';
import { chmodSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';

const repoRoot = resolve(import.meta.dirname, '../..');
const script = resolve(repoRoot, 'scripts/check-xcodeproj-drift.sh');
const releaseScript = resolve(repoRoot, 'macos/scripts/build-release.sh');
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

describe('release build xcodegen pin', () => {
  // Deploying 1.0.5 (1382) took three attempts: a bare `xcodegen generate` at
  // step 2 ran Homebrew's newer xcodegen, which rewrote project.pbxproj after
  // step 0 had already resolved the build number, so the archive would have
  // carried a drifted project. The release path must abort at the gate rather
  // than archive whatever the locally installed xcodegen happens to emit.
  it('aborts before archiving when the pinned xcodegen is unavailable', () => {
    // A fake HOME keeps step 1's DerivedData rm -rf inside the sandbox, and an
    // unusable XCODEGEN_BIN fails the gate regardless of what is installed.
    const home = mkdtempSync(resolve(tmpdir(), 'engram-relhome-'));
    let status = 0;
    let stdout = '';
    let stderr = '';
    try {
      stdout = execFileSync('bash', [releaseScript], {
        cwd: repoRoot,
        encoding: 'utf8',
        env: {
          ...process.env,
          HOME: home,
          XCODEGEN_BIN: '/nonexistent/xcodegen',
          XDG_CACHE_HOME: mkdtempSync(resolve(tmpdir(), 'engram-xg-')),
        },
        stdio: ['ignore', 'pipe', 'pipe'],
      });
    } catch (error) {
      const e = error as { status: number; stdout: string; stderr: string };
      status = e.status;
      stdout = e.stdout;
      stderr = e.stderr;
    }

    expect(status).not.toBe(0);
    expect(stderr).toContain('needs xcodegen');
    expect(stdout).toContain('[2/5]');
    expect(stdout).not.toContain('[3/5] Archiving');
  });
});
