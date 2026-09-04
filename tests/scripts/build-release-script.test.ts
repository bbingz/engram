// Real bundle-hygiene test for the macOS release pipeline.
//
// This used to assert on the *text* of build-release.sh (a meaningless pretense:
// it passed even when the script shipped a non-notarizable app). It now builds a
// stub .app on disk and exercises macos/scripts/release-verify.sh against it,
// asserting on the resulting bundle's actual structure and the script's pass/fail
// behavior — including that forbidden Node/dist artifacts are detected.

import { execFileSync, spawnSync } from 'node:child_process';
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';

const repoRoot = resolve(import.meta.dirname, '../..');
const verifyScript = resolve(repoRoot, 'macos/scripts/release-verify.sh');
const releaseScript = resolve(repoRoot, 'macos/scripts/build-release.sh');
const releaseWorkflow = resolve(repoRoot, '.github/workflows/release.yml');
const deployLocalScript = resolve(repoRoot, 'macos/scripts/deploy-local.sh');

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
  for (const framework of [
    'EngramServiceCore',
    'EngramCoreRead',
    'EngramCoreWrite',
    'GRDB-dynamic',
  ]) {
    mkdirSync(join(contents, 'Frameworks', `${framework}.framework`), {
      recursive: true,
    });
  }
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
  env: Record<string, string> = {},
): { code: number; out: string } {
  try {
    const out = execFileSync(
      '/bin/bash',
      [verifyScript, app, '--adhoc', ...extraArgs],
      {
        encoding: 'utf8',
        env: { ...process.env, ...env },
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

    it('fails closed when the hygiene find walk errors_repro', () => {
      const app = buildStubApp();
      const bin = join(workdir, 'bin');
      const find = join(bin, 'find');
      mkdirSync(bin);
      writeFileSync(find, '#!/bin/sh\nexit 73\n');
      chmodSync(find, 0o755);

      const { code } = runVerify(app, ['--hygiene-only'], {
        PATH: `${bin}:${process.env.PATH ?? ''}`,
      });

      expect(code).not.toBe(0);
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

describe('deploy-local process gate', () => {
  it('re-terminates app and service while treating MCP as best effort (repro)', () => {
    const source = readFileSync(deployLocalScript, 'utf8');
    expect(source).toContain('BLOCKING_PROCESS_NAMES=(Engram EngramService)');
    const waitLoop = source.slice(
      source.indexOf('for _ in 1 2 3'),
      source.indexOf('# Remove the existing install'),
    );
    const afterInstall = source.slice(
      source.indexOf('ditto "$SRC_APP" "$DEST_APP"'),
    );
    expect(waitLoop).toContain('pkill -TERM -x EngramMCP');
    expect(afterInstall).toContain('pkill -TERM -x EngramMCP');
    expect(source).toMatch(
      /for _ in 1 2 3[\s\S]*for process_name in "\$\{BLOCKING_PROCESS_NAMES\[@\]\}"; do[\s\S]*pkill -TERM -x "\$process_name"/,
    );
    expect(source).not.toContain(
      'PROCESS_NAMES=(Engram EngramService EngramMCP)',
    );
  });
});

describe('release workflow gate', () => {
  const workflow = readFileSync(releaseWorkflow, 'utf8');

  function acceptsReleaseTag(tag: string): boolean {
    const match = workflow.match(/\[\[ "\$GITHUB_REF_NAME" =~ ([^ ]+) \]\]/);
    expect(match).not.toBeNull();
    return (
      spawnSync('/bin/bash', ['-c', '[[ "$TAG" =~ $TAG_REGEX ]]'], {
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

  it('keeps the existing build paths when ENGRAM_BUILD_ROOT is unset', () => {
    const env: NodeJS.ProcessEnv = { ...process.env };
    delete env.ENGRAM_BUILD_ROOT;
    const result = spawnSync('/bin/bash', [releaseScript, '--print-paths'], {
      cwd: repoRoot,
      encoding: 'utf8',
      env,
    });

    expect(result.status).toBe(0);
    expect(result.stdout).toContain('BUILD_ROOT:        <unset>');
    expect(result.stdout).toContain('DERIVED_DATA_PATH: <xcode-default>');
    expect(result.stdout).toContain(
      `ARCHIVE_PATH:      ${repoRoot}/macos/build/Engram.xcarchive`,
    );
    expect(result.stdout).toContain(
      `EXPORT_LOG:        ${repoRoot}/macos/build/export.log`,
    );
    expect(result.stdout).toContain(
      `EXPORT_PATH:       ${repoRoot}/macos/build/EngramExport`,
    );
    expect(script).toContain(
      'rm -rf ~/Library/Developer/Xcode/DerivedData/Engram-*',
    );
  });

  it('routes only rebuildable intermediates through an opt-in build root', () => {
    const buildRoot = mkdtempSync(
      join(tmpdir(), 'engram-external-build-root-'),
    );
    try {
      const resolvedBuildRoot = realpathSync(buildRoot);
      const result = spawnSync('/bin/bash', [releaseScript, '--print-paths'], {
        cwd: repoRoot,
        encoding: 'utf8',
        env: { ...process.env, ENGRAM_BUILD_ROOT: buildRoot },
      });

      expect(result.status).toBe(0);
      expect(result.stdout).toContain(
        `BUILD_ROOT:        ${resolvedBuildRoot}`,
      );
      expect(result.stdout).toContain(
        `DERIVED_DATA_PATH: ${resolvedBuildRoot}/DerivedData`,
      );
      expect(result.stdout).toContain(
        `ARCHIVE_PATH:      ${resolvedBuildRoot}/Archives/Engram.xcarchive`,
      );
      expect(result.stdout).toContain(
        `EXPORT_LOG:        ${resolvedBuildRoot}/Logs/export.log`,
      );
      expect(result.stdout).toContain(
        `EXPORT_PATH:       ${repoRoot}/macos/build/EngramExport`,
      );
    } finally {
      rmSync(buildRoot, { recursive: true, force: true });
    }
  });

  it('rejects relative and overly broad opt-in build roots', () => {
    for (const buildRoot of [
      'relative/build-root',
      '/',
      join(tmpdir(), 'shared-build-root'),
    ]) {
      const result = spawnSync('/bin/bash', [releaseScript, '--print-paths'], {
        cwd: repoRoot,
        encoding: 'utf8',
        env: { ...process.env, ENGRAM_BUILD_ROOT: buildRoot },
      });

      expect(result.status).not.toBe(0);
      expect(`${result.stdout}${result.stderr}`).toContain(
        'ENGRAM_BUILD_ROOT must be an absolute project-scoped path',
      );
    }
  });

  it('resolves an existing symlink before enforcing project scope', () => {
    const sandbox = mkdtempSync(join(tmpdir(), 'engram-build-symlink-'));
    const realRoot = join(sandbox, 'shared-build-root');
    const linkedRoot = join(sandbox, 'Engram-build-root');
    mkdirSync(realRoot);
    symlinkSync(realRoot, linkedRoot);

    try {
      const result = spawnSync('/bin/bash', [releaseScript, '--print-paths'], {
        cwd: repoRoot,
        encoding: 'utf8',
        env: { ...process.env, ENGRAM_BUILD_ROOT: linkedRoot },
      });

      expect(result.status).not.toBe(0);
      expect(`${result.stdout}${result.stderr}`).toContain(
        'ENGRAM_BUILD_ROOT must be an absolute project-scoped path',
      );
    } finally {
      rmSync(sandbox, { recursive: true, force: true });
    }
  });

  it('fails closed instead of creating a missing volume mount', () => {
    const missingVolume = `/Volumes/engram-missing-build-volume-${process.pid}`;
    const result = spawnSync('/bin/bash', [releaseScript, '--print-paths'], {
      cwd: repoRoot,
      encoding: 'utf8',
      env: {
        ...process.env,
        ENGRAM_BUILD_ROOT: `${missingVolume}/XcodeBuilds/Engram`,
      },
    });

    expect(result.status).not.toBe(0);
    expect(`${result.stdout}${result.stderr}`).toContain(
      `external build volume is not mounted: ${missingVolume}`,
    );
  });

  it('does not hard-code a developer volume into the opt-in path', () => {
    expect(script).toContain('-derivedDataPath "$DERIVED_DATA_PATH"');
    expect(script).not.toContain('Bing-SSD-5');
  });

  it('never expands an empty archive argument array under macOS system Bash', () => {
    expect(script).not.toContain('XCODEBUILD_DERIVED_DATA_ARGS=()');
    expect(script).toMatch(/XCODEBUILD_ARCHIVE_ARGS=\(\s*archive/);
  });

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

  it('pins the marketing version in every candidate verification path', () => {
    expect(script).toContain(
      '"$SCRIPT_DIR/release-verify.sh" "$EXPORT_PATH/Engram-local-only.app" --adhoc --expected-build "$BUILD_NUMBER" --expected-short-version "$MARKETING_VERSION"',
    );
    expect(script).toContain(
      '"$SCRIPT_DIR/release-verify.sh" "$EXPORT_PATH/Engram.app" --expected-build "$BUILD_NUMBER" --expected-short-version "$MARKETING_VERSION"',
    );
    expect(script).toContain(
      'echo "  --expected-build \\"$BUILD_NUMBER\\" --expected-short-version \\"$MARKETING_VERSION\\" --require-notarization"',
    );
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

  it('requires Hardened Runtime before accepting an ad-hoc archive_repro', () => {
    const runtimeCheck = script.indexOf("grep -Eq 'flags=.*runtime'");
    const adhocSuccess = script.lastIndexOf('if [ "$ADHOC" -eq 1 ]; then');

    expect(runtimeCheck).toBeGreaterThan(-1);
    expect(adhocSuccess).toBeGreaterThan(-1);
    expect(runtimeCheck).toBeLessThan(adhocSuccess);
  });

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

// build-release.sh reads the team ID through /usr/libexec/PlistBuddy, so it can
// only be exercised end-to-end on macOS. This file is in the macos-vitest job's
// explicit list, so the test still runs in CI — on macos-15, not ubuntu.
describe.skipIf(process.platform !== 'darwin')(
  'release build xcodegen pin',
  () => {
    it('cleans only the opt-in intermediates before the xcodegen gate', () => {
      const home = mkdtempSync(join(tmpdir(), 'engram-relhome-'));
      const buildRoot = mkdtempSync(join(tmpdir(), 'engram-build-root-'));
      const xcodegenCache = mkdtempSync(join(tmpdir(), 'engram-xg-'));
      const xcodeDefaultSentinel = join(
        home,
        'Library/Developer/Xcode/DerivedData/Engram-keep/sentinel',
      );
      const derivedSentinel = join(buildRoot, 'DerivedData/stale');
      const archiveSentinel = join(
        buildRoot,
        'Archives/Engram.xcarchive/stale',
      );
      const siblingSentinel = join(buildRoot, 'keep.txt');
      mkdirSync(resolve(xcodeDefaultSentinel, '..'), { recursive: true });
      mkdirSync(resolve(derivedSentinel, '..'), { recursive: true });
      mkdirSync(resolve(archiveSentinel, '..'), { recursive: true });
      writeFileSync(xcodeDefaultSentinel, 'keep');
      writeFileSync(derivedSentinel, 'remove');
      writeFileSync(archiveSentinel, 'remove');
      writeFileSync(siblingSentinel, 'keep');

      try {
        const result = spawnSync('/bin/bash', [releaseScript], {
          cwd: repoRoot,
          encoding: 'utf8',
          env: {
            ...process.env,
            ENGRAM_BUILD_NUMBER: '99999',
            ENGRAM_BUILD_ROOT: buildRoot,
            HOME: home,
            XCODEGEN_BIN: '/nonexistent/xcodegen',
            XDG_CACHE_HOME: xcodegenCache,
          },
        });

        expect(result.status).not.toBe(0);
        expect(result.stdout).toContain('[2/5]');
        expect(existsSync(derivedSentinel)).toBe(false);
        expect(existsSync(archiveSentinel)).toBe(false);
        expect(existsSync(siblingSentinel)).toBe(true);
        expect(existsSync(xcodeDefaultSentinel)).toBe(true);
      } finally {
        rmSync(home, { recursive: true, force: true });
        rmSync(buildRoot, { recursive: true, force: true });
        rmSync(xcodegenCache, { recursive: true, force: true });
      }
    });

    // Deploying 1.0.5 (1382) took three attempts: a bare `xcodegen generate` at
    // step 2 ran Homebrew's newer xcodegen, which rewrote project.pbxproj after
    // step 0 had already resolved the build number as "clean" — so the archive
    // would have carried a drifted project under an official build number. The
    // release path must abort at the gate rather than archive whatever xcodegen
    // happens to be installed.
    it('aborts before archiving when the pinned xcodegen is unavailable', () => {
      // A fake HOME keeps step 1's DerivedData rm -rf inside the sandbox, and an
      // unusable XCODEGEN_BIN fails the gate regardless of what is installed.
      // ENGRAM_BUILD_NUMBER short-circuits step 0: CI checks out at depth 1, so
      // `rev-list --count HEAD` is 1 and the script would reject it as the
      // default placeholder before ever reaching the gate under test.
      const home = mkdtempSync(join(tmpdir(), 'engram-relhome-'));
      let status: number | null = 0;
      let stdout = '';
      let stderr = '';
      try {
        stdout = execFileSync('/bin/bash', [releaseScript], {
          cwd: repoRoot,
          encoding: 'utf8',
          env: {
            ...process.env,
            ENGRAM_BUILD_NUMBER: '99999',
            HOME: home,
            XCODEGEN_BIN: '/nonexistent/xcodegen',
            XDG_CACHE_HOME: mkdtempSync(join(tmpdir(), 'engram-xg-')),
          },
          stdio: ['ignore', 'pipe', 'pipe'],
        });
      } catch (error) {
        const e = error as { status: number; stdout: string; stderr: string };
        status = e.status;
        stdout = e.stdout;
        stderr = e.stderr;
      } finally {
        rmSync(home, { recursive: true, force: true });
      }

      expect(status).not.toBe(0);
      expect(stderr).toContain('needs xcodegen');
      expect(stdout).toContain('[2/5]');
      expect(stdout).not.toContain('[3/5] Archiving');
    });
  },
);
