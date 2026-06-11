import { execFileSync } from 'node:child_process';
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import sharp from 'sharp';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';

const repoRoot = resolve(import.meta.dirname, '../..');
const compareScript = resolve(repoRoot, 'scripts/screenshot-compare.ts');
const tsxBin = resolve(repoRoot, 'node_modules/.bin/tsx');
const workflowPath = resolve(repoRoot, '.github/workflows/test.yml');

let workdir: string;

function runCompare(env: Record<string, string> = {}): {
  code: number;
  out: string;
} {
  try {
    const out = execFileSync(tsxBin, [compareScript], {
      cwd: workdir,
      env: { ...process.env, ...env },
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    return { code: 0, out };
  } catch (err: unknown) {
    const e = err as { status?: number; stdout?: string; stderr?: string };
    return { code: e.status ?? 1, out: `${e.stdout ?? ''}${e.stderr ?? ''}` };
  }
}

function writeConfig() {
  mkdirSync(join(workdir, 'baselines'), { recursive: true });
  writeFileSync(
    join(workdir, 'screenshot-compare.config.json'),
    `${JSON.stringify(
      {
        ssim_threshold: 0.95,
        phash_max_distance: 8,
        pixel_diff_max_percent: 0.5,
        baselines_dir: 'baselines',
        ignore_regions: {},
      },
      null,
      2,
    )}\n`,
  );
}

function writeManifest(name: string) {
  mkdirSync(join(workdir, 'screenshots'), { recursive: true });
  writeFileSync(
    join(workdir, 'screenshots/test-manifest.json'),
    `${JSON.stringify({
      screenshots: [{ name }],
      environment: { suite: 'test' },
    })}\n`,
  );
}

describe('screenshot-compare gate behavior', () => {
  beforeEach(() => {
    workdir = mkdtempSync(join(tmpdir(), 'engram-screenshot-compare-'));
    writeConfig();
  });

  afterEach(() => {
    rmSync(workdir, { recursive: true, force: true });
  });

  it('fails when a manifest screenshot has no baseline', () => {
    writeManifest('missing-baseline');

    const result = runCompare({
      SCREENSHOTS_DIR: join(workdir, 'screenshots'),
      SCREENSHOT_REQUIRE_MANIFEST: '1',
    });

    expect(result.code).not.toBe(0);
    expect(result.out).toContain('New baselines are not allowed');
  });

  it('fails on size mismatch by default', async () => {
    writeManifest('size-mismatch');
    await sharp({
      create: {
        width: 20,
        height: 20,
        channels: 4,
        background: '#fff',
      },
    })
      .png()
      .toFile(join(workdir, 'baselines/size-mismatch.png'));
    await sharp({
      create: {
        width: 40,
        height: 20,
        channels: 4,
        background: '#fff',
      },
    })
      .png()
      .toFile(join(workdir, 'screenshots/size-mismatch.png'));

    const result = runCompare({
      SCREENSHOTS_DIR: join(workdir, 'screenshots'),
      SCREENSHOT_REQUIRE_MANIFEST: '1',
    });

    expect(result.code).not.toBe(0);
    expect(result.out).toContain('Size mismatches are not allowed');
  });
});

describe('UI workflow gates', () => {
  it('runs the full UI suite on pull requests', () => {
    const workflow = readFileSync(workflowPath, 'utf8');
    const fullJob = workflow.slice(workflow.indexOf('  ui-test-full:'));

    expect(fullJob).toContain("github.event_name == 'pull_request'");
    expect(fullJob).toContain('-only-testing:EngramUITests');
  });

  it('does not soft-pass screenshot size mismatches in CI', () => {
    const workflow = readFileSync(workflowPath, 'utf8');

    expect(workflow).not.toContain('SCREENSHOT_FAIL_ON_SIZE_MISMATCH: "0"');
  });
});
