import { spawnSync } from 'node:child_process';
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';

const repoRoot = resolve(import.meta.dirname, '../..');
const packageScriptPath = resolve(
  repoRoot,
  'macos/scripts/package-remote-server.sh',
);
const wrapperTemplatePath = resolve(
  repoRoot,
  'macos/EngramRemoteServer/Packaging/run-engram-remote.zsh.template',
);
const launchAgentTemplatePath = resolve(
  repoRoot,
  'macos/EngramRemoteServer/Packaging/com.engram.remote-server.plist.template',
);
const workflowPath = resolve(repoRoot, '.github/workflows/test.yml');
const offloadRunbookPath = resolve(repoRoot, 'docs/remote-offload.md');
const archiveRunbookPath = resolve(repoRoot, 'docs/remote-archive-v2.md');

const readIfPresent = (path: string): string =>
  existsSync(path) ? readFileSync(path, 'utf8') : '';

const packageScript = readIfPresent(packageScriptPath);
const wrapperTemplate = readIfPresent(wrapperTemplatePath);
const launchAgentTemplate = readIfPresent(launchAgentTemplatePath);
const workflow = readFileSync(workflowPath, 'utf8');
const offloadRunbook = readFileSync(offloadRunbookPath, 'utf8');
const archiveRunbook = readFileSync(archiveRunbookPath, 'utf8');

function shellFunctionBody(name: string): string {
  const start = packageScript.indexOf(`\n${name}() {`);
  if (start === -1) return '';
  const end = packageScript.indexOf('\n}\n', start);
  return end === -1
    ? packageScript.slice(start)
    : packageScript.slice(start, end);
}

let tempRoots: string[] = [];

afterEach(() => {
  for (const root of tempRoots) {
    rmSync(root, { force: true, recursive: true });
  }
  tempRoots = [];
});

function makeTempRoot(): string {
  const root = mkdtempSync(join(tmpdir(), 'engram-remote-package-test-'));
  tempRoots.push(root);
  return root;
}

function runPackage(args: string[]): { status: number | null; output: string } {
  const result = spawnSync('/bin/bash', [packageScriptPath, ...args], {
    cwd: repoRoot,
    encoding: 'utf8',
    env: { ...process.env, LC_ALL: 'C' },
  });
  return {
    status: result.status,
    output: `${result.stdout ?? ''}${result.stderr ?? ''}`,
  };
}

describe('remote server package command contract', () => {
  it('ships the package script and secret-free deployment templates', () => {
    expect(existsSync(packageScriptPath)).toBe(true);
    expect(existsSync(wrapperTemplatePath)).toBe(true);
    expect(existsSync(launchAgentTemplatePath)).toBe(true);
  });

  describe.skipIf(!existsSync(packageScriptPath))(
    'strict argument parsing',
    () => {
      it.each([
        { args: [], expected: 'usage:' },
        { args: ['--unknown'], expected: 'unknown argument' },
        {
          args: ['--verify-only', '/tmp/a', '--arch', 'arm64'],
          expected: 'cannot be combined',
        },
        {
          args: [
            '--derived-data',
            'relative/path',
            '--configuration',
            'Release',
            '--arch',
            'arm64',
            '--source-revision',
            'a'.repeat(40),
            '--output',
            '/tmp/output',
          ],
          expected: 'absolute',
        },
        {
          args: [
            '--derived-data',
            '/tmp/derived',
            '--configuration',
            'Debug',
            '--arch',
            'arm64',
            '--source-revision',
            'a'.repeat(40),
            '--output',
            '/tmp/output',
          ],
          expected: 'Release',
        },
        {
          args: [
            '--derived-data',
            '/tmp/derived',
            '--configuration',
            'Release',
            '--arch',
            'x86_64',
            '--source-revision',
            'a'.repeat(40),
            '--output',
            '/tmp/output',
          ],
          expected: 'arm64',
        },
        {
          args: [
            '--derived-data',
            '/tmp/derived',
            '--configuration',
            'Release',
            '--arch',
            'arm64',
            '--source-revision',
            'not-a-commit',
            '--output',
            '/tmp/output',
          ],
          expected: '40-character',
        },
      ])('rejects invalid invocation: $expected', ({ args, expected }) => {
        const result = runPackage(args);
        expect(result.status).not.toBe(0);
        expect(result.output).toContain(expected);
      });

      it('rejects a non-empty output before inspecting build products', () => {
        const root = makeTempRoot();
        const output = join(root, 'output');
        mkdirSync(output);
        writeFileSync(join(output, 'keep'), 'do not replace');

        const result = runPackage([
          '--derived-data',
          join(root, 'missing-derived-data'),
          '--configuration',
          'Release',
          '--arch',
          'arm64',
          '--source-revision',
          'a'.repeat(40),
          '--output',
          output,
        ]);

        expect(result.status).not.toBe(0);
        expect(result.output).toContain(
          'output directory must be new or empty',
        );
        expect(readFileSync(join(output, 'keep'), 'utf8')).toBe(
          'do not replace',
        );
      });
    },
  );
});

describe('remote server package implementation contract', () => {
  it('requires the fixed Release arm64 build products and package layout', () => {
    expect(packageScript).toMatch(
      /Build\/Products\/\$(?:CONFIGURATION|configuration)/,
    );
    expect(packageScript).toContain('bin/EngramRemoteServer');
    expect(packageScript).toContain('bin/swift-nio_NIOPosix.bundle');
    expect(packageScript).toContain(
      'Frameworks/EngramRemoteServerCore.framework',
    );
    expect(packageScript).toContain(
      'Frameworks/libswiftCompatibilitySpan.dylib',
    );
    expect(packageScript).toContain('templates/run-engram-remote.zsh.template');
    expect(packageScript).toContain(
      'templates/com.engram.remote-server.plist.template',
    );
    expect(packageScript).toContain('BUILD-METADATA.json');
    expect(packageScript).toContain('SHA256SUMS');
  });

  it('copies directory products with ditto and validates framework symlinks', () => {
    expect(packageScript).toMatch(
      /ditto[\s\\]+[^\n]+EngramRemoteServerCore\.framework/,
    );
    expect(packageScript).toMatch(
      /ditto[\s\\]+[^\n]+swift-nio_NIOPosix\.bundle/,
    );
    expect(packageScript).toContain('validate_framework_symlinks');
    expect(packageScript).toContain('Versions/Current');
    expect(packageScript).toContain('Versions/Current/Headers');
    expect(packageScript).toContain('Versions/Current/Modules');
    expect(packageScript).toContain('readlink');
    expect(shellFunctionBody('validate_framework_symlinks')).toContain(
      'framework="$(cd "$framework" && pwd -P)"',
    );
  });

  it('uses active-Xcode swift-stdlib-tool output for dependency closure', () => {
    expect(packageScript).toContain('xcrun --find swift-stdlib-tool');
    expect(packageScript).toContain('--print');
    expect(packageScript).toContain('--scan-executable');
    expect(packageScript).toContain('--scan-folder');
    expect(packageScript).toContain('--platform macosx');
    expect(packageScript).not.toMatch(/find[^\n]+libswiftCompatibilitySpan/);
  });

  it('thins before signing and signs dylibs, framework, then executable', () => {
    const thinIndex = packageScript.indexOf('thin_macho_to_arm64');
    const dylibSignIndex = packageScript.indexOf('sign_runtime_dylibs');
    const frameworkSignIndex = packageScript.indexOf(
      'codesign_bundle "$BUNDLE_FRAMEWORK"',
    );
    const executableSignIndex = packageScript.indexOf(
      'codesign_bundle "$BUNDLE_EXECUTABLE"',
    );

    expect(thinIndex).toBeGreaterThan(-1);
    expect(dylibSignIndex).toBeGreaterThan(thinIndex);
    expect(frameworkSignIndex).toBeGreaterThan(dylibSignIndex);
    expect(executableSignIndex).toBeGreaterThan(frameworkSignIndex);
  });

  it('verifies signatures, architecture, framework rpath, and dependency closure', () => {
    expect(packageScript).toContain('codesign --verify --deep --strict');
    expect(packageScript).toContain('lipo -verify_arch arm64');
    expect(packageScript).toContain('verify_arm64_only');
    expect(packageScript).toContain('[[ "$architectures" == "arm64" ]]');
    expect(packageScript).toContain('@executable_path/../Frameworks');
    expect(packageScript).toContain('verify_dependency_closure');
    expect(packageScript).toContain('otool -L');
    expect(packageScript).toContain('otool -l');
  });

  it('implements non-mutating verification and a sorted complete SHA-256 manifest', () => {
    expect(packageScript).toContain('--verify-only');
    expect(packageScript).toContain('verify_package');
    expect(packageScript).toContain('shasum -a 256 -c SHA256SUMS');
    expect(packageScript).toContain('LC_ALL=C sort');
    expect(packageScript).toContain('verify_manifest_file_set');
    expect(shellFunctionBody('verify_metadata')).toContain(
      'plutil -convert xml1 -o /dev/null',
    );
    expect(packageScript).not.toMatch(/rm\s+-rf\s+[^\n]*BUNDLE/);
  });

  it('keeps verify-only independent of Xcode and swift-stdlib-tool', () => {
    const verifyPackage = shellFunctionBody('verify_package');
    expect(verifyPackage).toContain('verify_dependency_closure');
    expect(verifyPackage).not.toContain('verify_swift_runtime_closure');
    expect(verifyPackage).not.toContain('xcrun');
    expect(verifyPackage).not.toContain('swift-stdlib-tool');
  });

  it('does not read or emit credential material', () => {
    expect(packageScript).not.toMatch(
      /\$(?:\{)?ENGRAM_REMOTE_(?:ARCHIVE_)?(?:TOKEN|AT_REST_KEY)/,
    );
    expect(packageScript).not.toMatch(/(?:source|printenv)[^\n]+\.env/);
    expect(packageScript).not.toContain('<key>EnvironmentVariables</key>');
    expect(packageScript).not.toMatch(/security\s+add-generic-password/);
  });
});

describe('owner-only deployment templates', () => {
  it('loads owner-only env files in the wrapper without embedding credentials', () => {
    expect(wrapperTemplate).toContain('#!/bin/zsh');
    expect(wrapperTemplate).toContain('umask 077');
    expect(wrapperTemplate).toContain('legacy-v1.env');
    expect(wrapperTemplate).toContain('archive-v2.env');
    expect(wrapperTemplate).not.toMatch(
      /ENGRAM_REMOTE_(?:ARCHIVE_)?(?:TOKEN|AT_REST_KEY)/,
    );
  });

  it('runs only the wrapper from launchd and has no environment dictionary', () => {
    expect(launchAgentTemplate).toContain('com.engram.remote-server');
    expect(launchAgentTemplate).toContain('ProgramArguments');
    expect(launchAgentTemplate).toContain('__ENGRAM_REMOTE_WRAPPER__');
    expect(launchAgentTemplate).not.toContain('EnvironmentVariables');
    expect(launchAgentTemplate).not.toMatch(/TOKEN|AT_REST_KEY/);
  });

  it('packages restrictive template permissions', () => {
    expect(packageScript).toContain('chmod 0700 "$BUNDLE_WRAPPER_TEMPLATE"');
    expect(packageScript).toContain(
      'chmod 0600 "$BUNDLE_LAUNCH_AGENT_TEMPLATE"',
    );
  });
});

describe('remote server package CI and operations documentation', () => {
  it('runs the package contract test in the exact macOS script matrix', () => {
    expect(workflow).toContain('tests/scripts/remote-server-package.test.ts');
  });

  it('builds, packages, verifies, then runs keygen in a clean environment', () => {
    const buildIndex = workflow.indexOf('Build Release remote server');
    const packageIndex = workflow.indexOf('package-remote-server.sh');
    const verifyIndex = workflow.indexOf('--verify-only');
    const cleanEnvironmentIndex = workflow.indexOf('env -i');
    const keygenIndex = workflow.indexOf('EngramRemoteServer" keygen');

    expect(buildIndex).toBeGreaterThan(-1);
    expect(packageIndex).toBeGreaterThan(buildIndex);
    expect(verifyIndex).toBeGreaterThan(packageIndex);
    expect(cleanEnvironmentIndex).toBeGreaterThan(verifyIndex);
    expect(keygenIndex).toBeGreaterThan(cleanEnvironmentIndex);
    expect(workflow).toContain('NO_XCODE_PATH=');
    expect(workflow).toContain('ln -s /usr/bin/false "$NO_XCODE_PATH/xcrun"');
    expect(workflow).toContain('PATH="$NO_XCODE_PATH:$PATH"');
  });

  it('documents the package command instead of the old manual Debug assembly', () => {
    expect(offloadRunbook).toContain('package-remote-server.sh');
    expect(offloadRunbook).toContain('--configuration Release');
    expect(offloadRunbook).not.toContain('Debug is fine');
    expect(offloadRunbook).not.toMatch(
      /find[^\n]+libswiftCompatibilitySpan\.dylib/,
    );
  });

  it('pins the v2 Tailscale Serve command and client origins', () => {
    expect(archiveRunbook).toContain(
      'tailscale serve --bg --https=443 --yes http://127.0.0.1:8787',
    );
    expect(archiveRunbook).toContain('https://macmini-hq.tail1cb16.ts.net');
    expect(archiveRunbook).toContain('https://macmini-m1.tail1cb16.ts.net');
    expect(archiveRunbook).toMatch(/8443[\s\S]{0,80}legacy-only/i);
    expect(archiveRunbook).toMatch(/FileVault[\s\S]{0,100}manual unlock/i);
  });
});
