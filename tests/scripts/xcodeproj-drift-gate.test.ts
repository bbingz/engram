import { execFileSync } from 'node:child_process';
import {
  chmodSync,
  copyFileSync,
  globSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';

const repoRoot = resolve(import.meta.dirname, '../..');
const script = resolve(repoRoot, 'scripts/check-xcodeproj-drift.sh');
const pbxproj = resolve(repoRoot, 'macos/Engram.xcodeproj/project.pbxproj');
const workflowPaths = [
  '.github/workflows/test.yml',
  '.github/workflows/codeql.yml',
  '.github/workflows/release.yml',
  '.github/workflows/perf.yml',
];

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

function runFixtureScript(
  fixtureScript: string,
  fixtureRoot: string,
  env: Record<string, string>,
): { status: number; stdout: string; stderr: string } {
  try {
    const stdout = execFileSync('bash', [fixtureScript], {
      cwd: fixtureRoot,
      encoding: 'utf8',
      env: {
        ...process.env,
        CI: '',
        GITHUB_ACTIONS: '',
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
    const status = execFileSync(
      'git',
      [
        'status',
        '--porcelain=v1',
        '--untracked-files=all',
        '--',
        'macos/Engram.xcodeproj',
      ],
      { cwd: repoRoot, encoding: 'utf8' },
    );
    return status.trim().length === 0;
  } catch {
    return false;
  }
})();

describe('xcodeproj drift gate', () => {
  it('routes every workflow project generation through the drift gate (repro)', () => {
    for (const workflowPath of workflowPaths) {
      const workflow = readFileSync(resolve(repoRoot, workflowPath), 'utf8');
      expect(workflow, workflowPath).not.toContain('xcodegen generate');
      expect(workflow, workflowPath).toContain(
        'scripts/check-xcodeproj-drift.sh',
      );
    }
    for (const scriptPath of globSync('scripts/**/*.ts', { cwd: repoRoot })) {
      const source = readFileSync(resolve(repoRoot, scriptPath), 'utf8');
      expect(source, scriptPath).not.toContain('xcodegen generate');
    }
    const baselineGenerator = readFileSync(
      resolve(repoRoot, 'scripts/baselines-generate.ts'),
      'utf8',
    );
    expect(baselineGenerator).toContain('scripts/check-xcodeproj-drift.sh');
  });

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
        expect(result.stderr).toContain('git add macos/Engram.xcodeproj');
      } finally {
        writeFileSync(pbxproj, original);
      }
    },
  );

  it('fails when regeneration leaves an untracked project file (repro)', () => {
    const fixtureRoot = mkdtempSync(resolve(tmpdir(), 'engram-xg-repo-'));
    const fixtureScript = resolve(
      fixtureRoot,
      'scripts/check-xcodeproj-drift.sh',
    );
    const projectRoot = resolve(fixtureRoot, 'macos/Engram.xcodeproj');
    mkdirSync(resolve(fixtureRoot, 'scripts'), { recursive: true });
    mkdirSync(resolve(fixtureRoot, '.github/workflows'), { recursive: true });
    mkdirSync(projectRoot, { recursive: true });
    copyFileSync(script, fixtureScript);
    chmodSync(fixtureScript, 0o755);
    writeFileSync(
      resolve(fixtureRoot, '.github/workflows/test.yml'),
      '  XCODEGEN_VERSION: "2.44.1"\n  XCODEGEN_SHA256: "fixture"\n',
    );
    writeFileSync(resolve(projectRoot, 'project.pbxproj'), '// clean\n');
    execFileSync('git', ['init', '-q'], { cwd: fixtureRoot });
    execFileSync('git', ['config', 'user.email', 'test@engram.local'], {
      cwd: fixtureRoot,
    });
    execFileSync('git', ['config', 'user.name', 'Engram Test'], {
      cwd: fixtureRoot,
    });
    execFileSync('git', ['add', '.'], { cwd: fixtureRoot });
    execFileSync('git', ['commit', '-qm', 'fixture'], { cwd: fixtureRoot });

    const untrackedScheme = resolve(
      projectRoot,
      'xcshareddata/xcschemes/rogue.xcscheme',
    );
    mkdirSync(resolve(untrackedScheme, '..'), { recursive: true });
    writeFileSync(untrackedScheme, '<Scheme/>\n');
    const result = runFixtureScript(fixtureScript, fixtureRoot, {
      XCODEGEN_BIN: stub('exit 0'),
      XDG_CACHE_HOME: resolve(fixtureRoot, 'cache'),
    });

    expect(result.status).toBe(1);
    expect(result.stderr).toContain('macos/Engram.xcodeproj');
  });

  it('allows an already-staged project update when regeneration adds no drift (repro)', () => {
    const fixtureRoot = mkdtempSync(resolve(tmpdir(), 'engram-xg-staged-'));
    const fixtureScript = resolve(
      fixtureRoot,
      'scripts/check-xcodeproj-drift.sh',
    );
    const projectRoot = resolve(fixtureRoot, 'macos/Engram.xcodeproj');
    mkdirSync(resolve(fixtureRoot, 'scripts'), { recursive: true });
    mkdirSync(resolve(fixtureRoot, '.github/workflows'), { recursive: true });
    mkdirSync(projectRoot, { recursive: true });
    copyFileSync(script, fixtureScript);
    chmodSync(fixtureScript, 0o755);
    writeFileSync(
      resolve(fixtureRoot, '.github/workflows/test.yml'),
      '  XCODEGEN_VERSION: "2.44.1"\n  XCODEGEN_SHA256: "fixture"\n',
    );
    const fixtureProject = resolve(projectRoot, 'project.pbxproj');
    writeFileSync(fixtureProject, '// clean\n');
    execFileSync('git', ['init', '-q'], { cwd: fixtureRoot });
    execFileSync('git', ['config', 'user.email', 'test@engram.local'], {
      cwd: fixtureRoot,
    });
    execFileSync('git', ['config', 'user.name', 'Engram Test'], {
      cwd: fixtureRoot,
    });
    execFileSync('git', ['add', '.'], { cwd: fixtureRoot });
    execFileSync('git', ['commit', '-qm', 'fixture'], { cwd: fixtureRoot });
    const generated = runFixtureScript(fixtureScript, fixtureRoot, {
      XCODEGEN_BIN: stub(
        `printf '// generated drift\\n' >> ${JSON.stringify(fixtureProject)}`,
      ),
      XDG_CACHE_HOME: resolve(fixtureRoot, 'cache'),
    });
    expect(generated.status).toBe(1);
    execFileSync('git', ['add', 'macos/Engram.xcodeproj/project.pbxproj'], {
      cwd: fixtureRoot,
    });

    const result = runFixtureScript(fixtureScript, fixtureRoot, {
      XCODEGEN_BIN: stub('exit 0'),
      XDG_CACHE_HOME: resolve(fixtureRoot, 'cache'),
      CI: 'true',
      GITHUB_ACTIONS: 'true',
    });

    expect(result.status).toBe(0);
    expect(result.stdout).toContain('xcodeproj drift ok');
  });
});
