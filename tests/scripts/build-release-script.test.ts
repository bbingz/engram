// Real bundle-hygiene test for the macOS release pipeline.
//
// This used to assert on the *text* of build-release.sh (a meaningless pretense:
// it passed even when the script shipped a non-notarizable app). It now builds a
// stub .app on disk and exercises macos/scripts/release-verify.sh against it,
// asserting on the resulting bundle's actual structure and the script's pass/fail
// behavior — including that forbidden Node/dist artifacts are detected.

import { execFileSync, spawnSync } from 'node:child_process';
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';

const repoRoot = resolve(import.meta.dirname, '../..');
const verifyScript = resolve(repoRoot, 'macos/scripts/release-verify.sh');
const releaseWorkflow = resolve(repoRoot, '.github/workflows/release.yml');

let workdir: string;

/** Build a minimal but structurally-valid stub Engram.app (no real signing). */
function buildStubApp(opts?: {
  bundleVersion?: string;
  shortVersion?: string;
  // Optional forbidden artifact to plant: relative path under the .app.
  forbidden?: string;
}): string {
  const app = join(workdir, 'Engram.app');
  const contents = join(app, 'Contents');
  mkdirSync(join(contents, 'MacOS'), { recursive: true });
  mkdirSync(join(contents, 'Helpers'), { recursive: true });
  writeFileSync(join(contents, 'MacOS', 'Engram'), '#!/bin/sh\nexit 0\n');
  writeFileSync(join(contents, 'Helpers', 'EngramMCP'), 'stub');
  writeFileSync(join(contents, 'Helpers', 'EngramService'), 'stub');
  writeFileSync(join(contents, 'Helpers', 'EngramCLI'), 'stub');

  const shortVersion = opts?.shortVersion ?? '0.1.0';
  const bundleVersion = opts?.bundleVersion ?? '12345';
  writeFileSync(
    join(contents, 'Info.plist'),
    `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleShortVersionString</key>
  <string>${shortVersion}</string>
  <key>CFBundleVersion</key>
  <string>${bundleVersion}</string>
</dict>
</plist>
`,
  );

  if (opts?.forbidden) {
    const target = join(app, opts.forbidden);
    mkdirSync(resolve(target, '..'), { recursive: true });
    writeFileSync(target, 'forbidden');
  }

  // Ad-hoc sign so `codesign --verify --deep --strict` can succeed on macOS.
  // Skipped automatically on non-macOS (codesign absent) — see runVerify().
  try {
    execFileSync('codesign', ['--force', '--sign', '-', app], {
      stdio: 'ignore',
    });
  } catch {
    // Either not on macOS or signing unavailable; the verify run is gated below.
  }
  return app;
}

/** Build the thinnest possible .app directory for hygiene-only checks. */
function buildBareApp(opts?: { forbidden?: string }): string {
  const app = join(workdir, 'Bare.app');
  mkdirSync(app, { recursive: true });

  if (opts?.forbidden) {
    const target = join(app, opts.forbidden);
    mkdirSync(resolve(target, '..'), { recursive: true });
    writeFileSync(target, 'forbidden');
  }

  return app;
}

function runVerify(
  app: string,
  extraArgs: string[],
): { code: number; out: string } {
  try {
    const out = execFileSync(
      'bash',
      [verifyScript, app, '--adhoc', ...extraArgs],
      {
        encoding: 'utf8',
        stdio: ['ignore', 'pipe', 'pipe'],
      },
    );
    return { code: 0, out };
  } catch (err: unknown) {
    const e = err as { status?: number; stdout?: string; stderr?: string };
    return { code: e.status ?? 1, out: `${e.stdout ?? ''}${e.stderr ?? ''}` };
  }
}

describe('macOS release-verify bundle hygiene', () => {
  beforeEach(() => {
    workdir = mkdtempSync(join(tmpdir(), 'engram-release-verify-'));
  });
  afterEach(() => {
    rmSync(workdir, { recursive: true, force: true });
  });

  // release-verify.sh reads CFBundleVersion via macOS-only PlistBuddy, which
  // is absent on Linux CI. Keep version/signature assertions macOS-only while
  // retaining the earlier filesystem-only hygiene checks on every platform.
  describe.skipIf(process.platform !== 'darwin')(
    'macOS plist + signing checks',
    () => {
      // A hand-built stub .app cannot pass `codesign --verify --deep --strict`
      // (its nested Helpers are not real Mach-O objects), so we assert that the
      // identity-independent stages (hygiene, structure, version) all report "ok"
      // before the script reaches the signature stage. The deep-verify + Hardened
      // Runtime + Developer ID assertions are validated against a real built bundle
      // in CI and during manual release runs, not against a stub.
      it('reports hygiene + structure + version ok for a clean stub bundle', () => {
        const app = buildStubApp({ bundleVersion: '777' });
        const { out } = runVerify(app, ['--expected-build', '777']);
        expect(out).toContain('bundle hygiene clean');
        expect(out).toContain('structure present');
        expect(out).toContain('version short=0.1.0 build=777');
      });

      it('fails when the shipped EngramCLI helper is absent', () => {
        const app = buildStubApp();
        rmSync(join(app, 'Contents', 'Helpers', 'EngramCLI'));
        const { code, out } = runVerify(app, []);
        expect(code).not.toBe(0);
        expect(out).toContain('missing Contents/Helpers/EngramCLI');
      });
    },
  );

  // Hygiene detection happens before plist/codesign checks, so it remains a
  // useful cross-platform guard even when PlistBuddy is unavailable.
  for (const forbidden of [
    'Contents/Resources/node',
    'Contents/Resources/dist/index.js',
    'Contents/Resources/node_modules/foo.js',
    'Contents/Resources/daemon.js',
    'Contents/Resources/web.js',
  ]) {
    it(`fails when forbidden artifact is present: ${forbidden}`, () => {
      const app = buildStubApp({ forbidden });
      const { code, out } = runVerify(app, []);
      expect(code).not.toBe(0);
      expect(out).toContain('forbidden');
    });
  }

  describe('hygiene-only mode', () => {
    // M11: --hygiene-only still runs structural helper checks so per-PR CI
    // catches a dropped EngramMCP/CLI/Service bundling script.
    it('passes hygiene + structure without version or codesign checks', () => {
      const app = buildStubApp();
      const { code, out } = runVerify(app, ['--hygiene-only']);
      expect(code).toBe(0);
      expect(out).toContain('bundle hygiene clean');
      expect(out).toContain('structure present');
      expect(out).toContain('release-verify: PASS (hygiene + structure only)');
      expect(out).not.toContain('version short=');
    });

    it('fails when a helper is missing under hygiene-only (M11)', () => {
      const app = buildStubApp();
      rmSync(join(app, 'Contents', 'Helpers', 'EngramMCP'));
      const { code, out } = runVerify(app, ['--hygiene-only']);
      expect(code).not.toBe(0);
      expect(out).toContain('missing Contents/Helpers/EngramMCP');
    });

    it('fails for a bare app missing the executable tree', () => {
      const app = buildBareApp();
      const { code, out } = runVerify(app, ['--hygiene-only']);
      expect(code).not.toBe(0);
      expect(out).toContain('missing main executable Contents/MacOS/Engram');
    });

    it('still fails when a forbidden artifact is present', () => {
      const app = buildBareApp({
        forbidden: 'Contents/Resources/node_modules/foo.js',
      });
      const { code, out } = runVerify(app, ['--hygiene-only']);
      expect(code).not.toBe(0);
      expect(out).toContain('forbidden');
    });
  });

  describe.skipIf(process.platform !== 'darwin')('macOS version checks', () => {
    // Version checks run at stage 3, before the signature stage, so they do not
    // depend on codesign.
    it('fails on an empty / unsubstituted version token', () => {
      const app = buildStubApp({ bundleVersion: '$(CURRENT_PROJECT_VERSION)' });
      const { code, out } = runVerify(app, []);
      expect(code).not.toBe(0);
      expect(out).toContain('unsubstituted build-setting token');
    });

    it('fails when expected build number does not match', () => {
      const app = buildStubApp({ bundleVersion: '100' });
      const { code, out } = runVerify(app, ['--expected-build', '200']);
      expect(code).not.toBe(0);
      expect(out).toContain("!= expected '200'");
    });

    it('fails when expected short version does not match', () => {
      const app = buildStubApp({ shortVersion: '0.1.0' });
      const { code, out } = runVerify(app, [
        '--expected-short-version',
        '1.0.3',
      ]);
      expect(code).not.toBe(0);
      expect(out).toContain(
        "CFBundleShortVersionString '0.1.0' != expected '1.0.3'",
      );
    });
  });
});

describe('release workflow gate', () => {
  const workflow = readFileSync(releaseWorkflow, 'utf8');

  function acceptsReleaseTag(tag: string): boolean {
    const match = workflow.match(/\[\[ "\$GITHUB_REF_NAME" =~ ([^ ]+) \]\]/);
    expect(match).not.toBeNull();
    return (
      spawnSync('bash', ['-c', '[[ "$TAG" =~ $TAG_REGEX ]]'], {
        env: { ...process.env, TAG: tag, TAG_REGEX: match?.[1] ?? '' },
      }).status === 0
    );
  }

  it('only runs for semver-style v tags', () => {
    expect(workflow).toContain("- 'v*'");
    expect(workflow).not.toContain("- '*'");
  });

  it('validates the pushed tag against the app short version', () => {
    expect(workflow).toContain(
      '[[ "$GITHUB_REF_NAME" =~ ^v(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$ ]]',
    );
    for (const tag of ['v0.0.0', 'v1.2.3', 'v10.20.30']) {
      expect(acceptsReleaseTag(tag), tag).toBe(true);
    }
    for (const tag of [
      'v01.2.3',
      'v1.02.3',
      'v1.2.03',
      'v1.2.3-rc.1',
      'v1.2.3+build.1',
    ]) {
      expect(acceptsReleaseTag(tag), tag).toBe(false);
    }
    expect(workflow).toContain('TAG_VERSION="' + '$' + '{GITHUB_REF_NAME#v}"');
    expect(workflow).toContain('--expected-short-version "$TAG_VERSION"');
  });

  it('states that the ad-hoc gate is not distribution approval', () => {
    expect(workflow).toContain(
      'not a signed or notarized distribution approval',
    );
  });

  it('requires release tests before archive verification', () => {
    expect(workflow).toContain('release-tests:');
    expect(workflow).toContain('release-remote-server-tests:');
    expect(workflow).toContain(
      'needs: [release-tests, release-remote-server-tests]',
    );
  });
});

describe('macOS release build script: no silent non-notarizable fallback', () => {
  // Guard against REL-C1 regression: the old script ditto-fell-back to the
  // Apple-Development-signed archive app on export failure while printing success.
  // The replacement must only do that under an explicit --local-only flag and must
  // label it non-distributable.
  const script = execFileSync('cat', [
    resolve(repoRoot, 'macos/scripts/build-release.sh'),
  ]).toString();

  it('does not unconditionally ditto the archived app on export failure', () => {
    // Any ditto of the archived app must be guarded by the --local-only branch.
    const fallbackIdx = script.indexOf('ditto "$ARCHIVED_APP"');
    if (fallbackIdx !== -1) {
      const localOnlyIdx = script.indexOf('LOCAL_ONLY');
      expect(localOnlyIdx).toBeGreaterThan(-1);
      expect(script).toContain('NON-DISTRIBUTABLE');
    }
  });

  it('invokes release-verify.sh on the exported app', () => {
    expect(script).toContain('release-verify.sh');
  });

  it('does not reuse the git commit count for dirty local release builds', () => {
    expect(script).toContain(
      'git -C "$MACOS_DIR" diff --quiet --ignore-submodules --',
    );
    expect(script).toContain(
      'git -C "$MACOS_DIR" ls-files --others --exclude-standard',
    );
    expect(script).toContain('WORKTREE_DIRTY=1');
    expect(script).toContain('if [[ "$WORKTREE_DIRTY" -eq 0 ]]');
  });

  it('uses a second-resolution UTC timestamp when a unique local build number is needed', () => {
    expect(script).toContain('date -u +%Y%m%d%H%M%S');
  });

  it('uses a Keychain profile and verifies the stapled release before distribution', () => {
    expect(script).toContain(
      'notarytool store-credentials \\"engram-notary\\"',
    );
    expect(script).toContain('--keychain-profile \\"engram-notary\\"');
    expect(script).toContain('--require-notarization');
    expect(script).not.toContain('--password "YOUR_APP_SPECIFIC_PASSWORD"');
  });
});

describe('macOS release notarization verification', () => {
  const script = readFileSync(verifyScript, 'utf8');

  it('checks both the stapled ticket and Gatekeeper assessment', () => {
    expect(script).toContain('--require-notarization');
    expect(script).toContain('xcrun stapler validate');
    expect(script).toContain('spctl --assess --type execute');
  });

  it('rejects notarization assertions for an ad-hoc bundle', () => {
    workdir = mkdtempSync(join(tmpdir(), 'engram-release-verify-'));
    try {
      const app = buildBareApp();
      const { code, out } = runVerify(app, ['--require-notarization']);
      expect(code).not.toBe(0);
      expect(out).toContain('cannot be combined with --adhoc');
    } finally {
      rmSync(workdir, { recursive: true, force: true });
    }
  });
});
