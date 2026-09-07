import { Buffer } from 'node:buffer';
import { spawnSync } from 'node:child_process';
import {
  chmodSync,
  existsSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  readlinkSync,
  renameSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';

const repoRoot = resolve(import.meta.dirname, '../..');
const packageScriptPath = resolve(
  repoRoot,
  'macos/scripts/package-collector.sh',
);
const remotePackageScriptPath = resolve(
  repoRoot,
  'macos/scripts/package-remote-server.sh',
);
const projectYmlPath = resolve(repoRoot, 'macos/project.yml');

const packageScript = existsSync(packageScriptPath)
  ? readFileSync(packageScriptPath, 'utf8')
  : '';
const projectYml = readFileSync(projectYmlPath, 'utf8');

const revision = 'a'.repeat(40);
const forbiddenPackageNames = [
  'EngramCoreRead',
  'EngramCoreWrite',
  'EngramService',
  'Engram.app',
  'node_modules',
  'daemon.js',
  'index.js',
  'web.js',
];

let tempRoots: string[] = [];

afterEach(() => {
  for (const root of tempRoots) {
    rmSync(root, { force: true, recursive: true });
  }
  tempRoots = [];
});

function makeTempRoot(): string {
  const root = mkdtempSync(join(tmpdir(), 'engram-collector-package-test-'));
  tempRoots.push(root);
  return root;
}

function runPackage(
  args: string[],
  env: NodeJS.ProcessEnv = process.env,
): { status: number | null; output: string } {
  const result = spawnSync('/bin/bash', [packageScriptPath, ...args], {
    cwd: repoRoot,
    encoding: 'utf8',
    env: { ...env, LC_ALL: 'C' },
  });
  return {
    status: result.status,
    output: `${result.stdout ?? ''}${result.stderr ?? ''}`,
  };
}

function packagingArgs(root: string): string[] {
  return [
    '--derived-data',
    join(root, 'derived'),
    '--configuration',
    'Release',
    '--arch',
    'arm64',
    '--source-revision',
    revision,
    '--output',
    join(root, 'output'),
  ];
}

function writeSyntheticVersionedFramework(
  frameworkRoot: string,
  binaryName: string,
  contents: string,
): string {
  const versioned = join(frameworkRoot, 'Versions/A');
  mkdirSync(versioned, { recursive: true });
  const binary = join(versioned, binaryName);
  writeFileSync(binary, contents);
  chmodSync(binary, 0o700);
  symlinkSync('A', join(frameworkRoot, 'Versions/Current'));
  symlinkSync(
    `Versions/Current/${binaryName}`,
    join(frameworkRoot, binaryName),
  );
  return binary;
}

function writeSyntheticGRDBDynamic(frameworkRoot: string): string {
  return writeSyntheticVersionedFramework(
    frameworkRoot,
    'GRDB-dynamic',
    'synthetic-grdb\n',
  );
}

function writeSyntheticCollectorCore(frameworkRoot: string): string {
  return writeSyntheticVersionedFramework(
    frameworkRoot,
    'EngramCollectorCore',
    'synthetic-collector-core\n',
  );
}

function writeSyntheticBundle(
  bundle: string,
  options: { omitCore?: boolean; tamperManifest?: boolean } = {},
): void {
  mkdirSync(join(bundle, 'bin'), { recursive: true });
  writeFileSync(join(bundle, 'bin/EngramCollector'), 'synthetic-collector\n');
  chmodSync(join(bundle, 'bin/EngramCollector'), 0o700);
  writeSyntheticGRDBDynamic(join(bundle, 'Frameworks/GRDB-dynamic.framework'));
  if (!options.omitCore) {
    writeSyntheticCollectorCore(
      join(bundle, 'Frameworks/EngramCollectorCore.framework'),
    );
  }
  writeFileSync(
    join(bundle, 'BUILD-METADATA.json'),
    `${JSON.stringify(
      {
        schemaVersion: 1,
        product: 'EngramCollector',
        role: 'collector',
        configuration: 'Release',
        architecture: 'arm64',
        sourceRevision: revision,
      },
      null,
      2,
    )}\n`,
  );
  chmodSync(join(bundle, 'BUILD-METADATA.json'), 0o600);
  const files = [
    'BUILD-METADATA.json',
    'bin/EngramCollector',
    'Frameworks/GRDB-dynamic.framework/Versions/A/GRDB-dynamic',
  ];
  if (!options.omitCore) {
    files.push(
      'Frameworks/EngramCollectorCore.framework/Versions/A/EngramCollectorCore',
    );
  }
  files.push(...copyCollectorLaunchTemplates(bundle));
  files.sort();
  const sums = files
    .map((relative) => {
      const digest = spawnSync('/usr/bin/shasum', ['-a', '256', relative], {
        cwd: bundle,
        encoding: 'utf8',
      });
      return digest.stdout.trim();
    })
    .join('\n');
  writeFileSync(
    join(bundle, 'SHA256SUMS'),
    options.tamperManifest
      ? sums.replace(/^[0-9a-f]{64}/, 'b'.repeat(64))
      : `${sums}\n`,
  );
  chmodSync(join(bundle, 'SHA256SUMS'), 0o600);
}

function bashSingleQuote(value: string): string {
  return `'${value.replace(/'/g, `'\\''`)}'`;
}

function extractShellFunction(source: string, name: string): string {
  const signature = `${name}() {`;
  const start = source.indexOf(signature);
  if (start < 0) {
    throw new Error(`missing shell function ${name}`);
  }
  let depth = 0;
  for (let index = start; index < source.length; index += 1) {
    const character = source[index];
    if (character === '{') {
      depth += 1;
    } else if (character === '}') {
      depth -= 1;
      if (depth === 0) {
        return source.slice(start, index + 1);
      }
    }
  }
  throw new Error(`unclosed shell function ${name}`);
}

function extractShippedFunctions(names: string[]): string {
  return names
    .map((name) => extractShellFunction(packageScript, name))
    .join('\n\n');
}

function shippedDependencyClosureSource(): string {
  const extracted = extractShippedFunctions([
    'canonical_existing_path',
    'assert_safe_system_dependency',
    'assert_in_package_manifest_path',
    'verify_dependency_closure_for_binary',
  ]);
  expect(extracted).toContain('verify_dependency_closure_for_binary() {');
  expect(extracted).toContain('@rpath/*');
  expect(extracted).toContain('@executable_path/*');
  expect(extracted).toContain('@loader_path/*');
  expect(extracted).toContain('/usr/lib/*');
  expect(extracted).toContain('/usr/bin/otool -L');
  return extracted;
}

function alignUp(value: number, alignment: number): number {
  return Math.ceil(value / alignment) * alignment;
}

// Header-only MH_EXECUTE so real otool -L can parse LC_LOAD_DYLIB without a native build.
function writeSyntheticMachOWithLoadDylibs(
  filePath: string,
  dylibs: string[],
): void {
  const mhMagic64 = 0xfeedfacf;
  const cpuTypeArm64 = 0x0100000c;
  const mhExecute = 2;
  const lcLoadDylib = 0x0c;
  const headerSize = 32;
  const dylibCommandBase = 24;
  const commands = dylibs.map((name) => {
    const nameBytes = Buffer.from(`${name}\0`, 'utf8');
    const commandSize = alignUp(dylibCommandBase + nameBytes.length, 8);
    const command = Buffer.alloc(commandSize);
    command.writeUInt32LE(lcLoadDylib, 0);
    command.writeUInt32LE(commandSize, 4);
    command.writeUInt32LE(dylibCommandBase, 8);
    command.writeUInt32LE(0, 12);
    command.writeUInt32LE(0x10000, 16);
    command.writeUInt32LE(0x10000, 20);
    nameBytes.copy(command, dylibCommandBase);
    return command;
  });
  const sizeofcmds = commands.reduce((sum, command) => sum + command.length, 0);
  const header = Buffer.alloc(headerSize);
  header.writeUInt32LE(mhMagic64, 0);
  header.writeUInt32LE(cpuTypeArm64, 4);
  header.writeUInt32LE(0, 8);
  header.writeUInt32LE(mhExecute, 12);
  header.writeUInt32LE(dylibs.length, 16);
  header.writeUInt32LE(sizeofcmds, 20);
  header.writeUInt32LE(0, 24);
  header.writeUInt32LE(0, 28);
  writeFileSync(filePath, Buffer.concat([header, ...commands]));
  chmodSync(filePath, 0o644);
}

function runExtractedDependencyClosure(
  bundle: string,
  binary: string,
): { status: number | null; output: string } {
  const script = [
    'set -euo pipefail',
    'fail() { echo "package-collector: ERROR: $*" >&2; exit 1; }',
    shippedDependencyClosureSource(),
    `verify_dependency_closure_for_binary ${bashSingleQuote(bundle)} ${bashSingleQuote(binary)}`,
  ].join('\n');
  const result = spawnSync('/bin/bash', ['-s'], {
    encoding: 'utf8',
    env: { ...process.env, LC_ALL: 'C' },
    input: script,
  });
  return {
    status: result.status,
    output: `${result.stdout ?? ''}${result.stderr ?? ''}`,
  };
}

function assertOtoolParsesLoadPath(binary: string, loadPath: string): void {
  const otool = spawnSync('/usr/bin/otool', ['-L', binary], {
    encoding: 'utf8',
  });
  expect(otool.status).toBe(0);
  expect(otool.stdout).toContain(loadPath);
  expect(lstatSync(binary).mode & 0o111).toBe(0);
}

function shippedLayoutSource(): string {
  const extracted = extractShippedFunctions([
    'assert_unaliased_directory',
    'assert_unaliased_versioned_framework',
    'verify_package_layout',
  ]);
  expect(extracted).toContain('verify_package_layout() {');
  expect(extracted).toContain('Versions/A/EngramCollectorCore');
  expect(extracted).toContain('Versions/A/GRDB-dynamic');
  expect(extracted).toContain('! -L');
  return extracted;
}

function runExtractedLayout(bundle: string): {
  status: number | null;
  output: string;
} {
  const script = [
    'set -euo pipefail',
    'fail() { echo "package-collector: ERROR: $*" >&2; exit 1; }',
    shippedLayoutSource(),
    `verify_package_layout ${bashSingleQuote(bundle)}`,
  ].join('\n');
  const result = spawnSync('/bin/bash', ['-s'], {
    encoding: 'utf8',
    env: { ...process.env, LC_ALL: 'C' },
    input: script,
  });
  return {
    status: result.status,
    output: `${result.stdout ?? ''}${result.stderr ?? ''}`,
  };
}

function shippedNativeFrameworkFindPipeline(): string {
  const native = extractShellFunction(packageScript, 'verify_native_closure');
  const findIndex = native.indexOf('/usr/bin/find "$bundle/Frameworks"');
  expect(findIndex).toBeGreaterThan(-1);
  const lines = native
    .slice(findIndex)
    .split('\n')
    .map((line) => line.trim());
  const findLine = lines[0] ?? '';
  const sortLine = lines[1] ?? '';
  expect(findLine).toContain("-path '*/Versions/A/EngramCollectorCore'");
  expect(findLine).toContain("-path '*/Versions/A/GRDB-dynamic'");
  expect(findLine).toContain('-type f');
  expect(findLine).not.toMatch(/(?:^|[\s])-L(?:[\s]|$)/);
  expect(findLine).not.toContain('-follow');
  expect(sortLine.startsWith('LC_ALL=C sort')).toBe(true);
  return `${findLine}\n${sortLine}`;
}

function runShippedNativeFrameworkFind(bundle: string): string[] {
  const script = [
    `bundle=${bashSingleQuote(bundle)}`,
    shippedNativeFrameworkFindPipeline(),
  ].join('\n');
  const result = spawnSync('/bin/bash', ['-s'], {
    encoding: 'utf8',
    env: { ...process.env, LC_ALL: 'C' },
    input: script,
  });
  expect(result.status).toBe(0);
  return (result.stdout ?? '').split('\n').filter((line) => line.length > 0);
}

function aliasVersionDirectoryAToB(frameworkRoot: string): void {
  const versions = join(frameworkRoot, 'Versions');
  renameSync(join(versions, 'A'), join(versions, 'B'));
  symlinkSync('B', join(versions, 'A'));
}

function writeSha256Sums(bundle: string, files: string[]): void {
  const sorted = [
    ...new Set([
      ...files,
      ...collectorTemplateFiles.filter((relative) => {
        const directory = join(bundle, 'templates');
        if (!existsSync(directory)) return false;
        const parent = lstatSync(directory);
        if (!parent.isDirectory() || parent.isSymbolicLink()) return false;
        const path = join(bundle, relative);
        if (!existsSync(path)) return false;
        const entry = lstatSync(path);
        return entry.isFile() && !entry.isSymbolicLink();
      }),
    ]),
  ].sort();
  const sums = sorted
    .map((relative) => {
      const digest = spawnSync('/usr/bin/shasum', ['-a', '256', relative], {
        cwd: bundle,
        encoding: 'utf8',
      });
      return digest.stdout.trim();
    })
    .join('\n');
  writeFileSync(join(bundle, 'SHA256SUMS'), `${sums}\n`);
  chmodSync(join(bundle, 'SHA256SUMS'), 0o600);
}

const mandatoryVersionedEntities = [
  'Frameworks/EngramCollectorCore.framework/Versions/A/EngramCollectorCore',
  'Frameworks/GRDB-dynamic.framework/Versions/A/GRDB-dynamic',
];

describe('collector package command contract', () => {
  it('ships the collector package script beside the remote-server packager', () => {
    expect(existsSync(packageScriptPath)).toBe(true);
    expect(existsSync(remotePackageScriptPath)).toBe(true);
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
          args: ['--verify-only', '/tmp/a', '--dry-run'],
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
            revision,
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
            revision,
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
            revision,
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
          revision,
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

describe('collector package role and dependency closure', () => {
  it('names the frozen collector product and required frameworks', () => {
    expect(packageScript).toContain('bin/EngramCollector');
    expect(packageScript).toContain('EngramCollectorCore.framework');
    expect(packageScript).toContain('GRDB');
    expect(packageScript).toContain('product": "EngramCollector"');
    expect(packageScript).toContain('"role": "collector"');
    expect(packageScript).toContain('BUILD-METADATA.json');
    expect(packageScript).toContain('SHA256SUMS');
    expect(projectYml).toContain('product: GRDB-dynamic');
    expect(projectYml).toContain('sdk: CoreServices.framework');
  });

  it('excludes product index, CoreRead/Write, Service, App, and Node from the package', () => {
    for (const name of forbiddenPackageNames) {
      expect(packageScript).toContain(name);
    }
    expect(packageScript).toMatch(
      /fail[^\n]+EngramCoreRead|EngramCoreRead[^\n]+fail/,
    );
    expect(packageScript).not.toContain('Engram.app/Contents');
    expect(packageScript).not.toMatch(/cp[^\n]+node_modules/);
    expect(packageScript).not.toMatch(/ditto[^\n]+EngramCoreWrite/);
  });

  it('implements non-mutating verify-only and dry-run without install or user-state writes', () => {
    expect(packageScript).toContain('--verify-only');
    expect(packageScript).toContain('--dry-run');
    expect(packageScript).toContain('verify_package');
    expect(packageScript).toContain('shasum -a 256 -c SHA256SUMS');
    expect(packageScript).not.toContain('launchctl');
    expect(packageScript).not.toContain('Library/LaunchAgents');
    expect(packageScript).not.toMatch(/\$HOME\/\.engram/);
    expect(packageScript).not.toContain('settings.json');
  });
});

describe('collector package synthetic fixture gate', () => {
  it('rejects a missing EngramCollectorCore framework in verify-only', () => {
    const root = makeTempRoot();
    const bundle = join(root, 'bundle');
    writeSyntheticBundle(bundle, { omitCore: true });
    const before = readdirSync(bundle).sort().join('\n');

    const result = runPackage(['--verify-only', bundle]);

    expect(result.status).not.toBe(0);
    expect(result.output).toMatch(/EngramCollectorCore|missing/);
    expect(readdirSync(bundle).sort().join('\n')).toBe(before);
  });

  it('rejects a tampered SHA256SUMS in verify-only without mutating the bundle', () => {
    const root = makeTempRoot();
    const bundle = join(root, 'bundle');
    writeSyntheticBundle(bundle, { tamperManifest: true });
    const before = readFileSync(join(bundle, 'SHA256SUMS'), 'utf8');

    const result = runPackage(['--verify-only', bundle]);

    expect(result.status).not.toBe(0);
    expect(result.output).toMatch(/SHA256SUMS|mismatch|verification failed/);
    expect(readFileSync(join(bundle, 'SHA256SUMS'), 'utf8')).toBe(before);
  });

  it('dry-run does not create the output bundle or write user config or service state', () => {
    const root = makeTempRoot();
    const home = join(root, 'home');
    mkdirSync(join(home, 'Library/LaunchAgents'), { recursive: true });
    mkdirSync(join(root, 'derived'), { recursive: true });
    const output = join(root, 'output');
    const agents = join(home, 'Library/LaunchAgents');

    const result = runPackage(['--dry-run', ...packagingArgs(root)], {
      ...process.env,
      HOME: home,
    });

    expect(result.status).toBe(0);
    expect(result.output).toMatch(/dry-run|EngramCollector/);
    expect(existsSync(output)).toBe(false);
    expect(existsSync(join(home, '.engram'))).toBe(false);
    expect(existsSync(join(home, '.engram/settings.json'))).toBe(false);
    expect(readdirSync(agents)).toEqual([]);
  });
});

describe('collector package fail-closed path safety', () => {
  it('rejects an escaping framework Versions symlink before Mach-O thin/sign and preserves the sentinel', () => {
    const root = makeTempRoot();
    const products = join(root, 'derived/Build/Products/Release');
    const core = join(products, 'EngramCollectorCore.framework');
    const versioned = join(core, 'Versions/A');
    const grdb = join(products, 'PackageFrameworks/GRDB-dynamic.framework');
    const sentinel = join(root, 'outside-sentinel.txt');
    mkdirSync(versioned, { recursive: true });
    writeFileSync(join(products, 'EngramCollector'), 'synthetic-collector\n');
    chmodSync(join(products, 'EngramCollector'), 0o700);
    writeSyntheticGRDBDynamic(grdb);
    writeFileSync(sentinel, 'benign-sentinel\n');
    chmodSync(sentinel, 0o600);
    symlinkSync('A', join(core, 'Versions/Current'));
    symlinkSync(sentinel, join(versioned, 'EngramCollectorCore'));
    symlinkSync(
      'Versions/Current/EngramCollectorCore',
      join(core, 'EngramCollectorCore'),
    );

    const result = runPackage(packagingArgs(root));

    expect(result.status).not.toBe(0);
    expect(result.output).toMatch(/symlink|escapes package|unsafe path/i);
    expect(result.output).not.toMatch(
      /not a native Mach-O|cannot package a non-Mach-O/,
    );
    expect(readFileSync(sentinel, 'utf8')).toBe('benign-sentinel\n');
    expect(readFileSync(join(products, 'EngramCollector'), 'utf8')).toBe(
      'synthetic-collector\n',
    );
    expect(readFileSync(join(grdb, 'Versions/A/GRDB-dynamic'), 'utf8')).toBe(
      'synthetic-grdb\n',
    );
    expect(readFileSync(join(versioned, 'EngramCollectorCore'), 'utf8')).toBe(
      'benign-sentinel\n',
    );
  });

  it('verify-only rejects a SHA256SUMS traversal path without writing outside the bundle', () => {
    const root = makeTempRoot();
    const bundle = join(root, 'bundle');
    const sentinel = join(root, 'outside-sentinel.txt');
    writeSyntheticBundle(bundle);
    writeFileSync(sentinel, 'benign-sentinel\n');
    writeFileSync(
      join(bundle, 'SHA256SUMS'),
      `${'c'.repeat(64)}  ../outside-sentinel.txt\n`,
    );
    const before = readFileSync(join(bundle, 'SHA256SUMS'), 'utf8');

    const result = runPackage(['--verify-only', bundle]);

    expect(result.status).not.toBe(0);
    expect(result.output).toMatch(/unsafe manifest path|escapes package/);
    expect(result.output).not.toMatch(
      /not a native Mach-O|cannot package a non-Mach-O/,
    );
    expect(readFileSync(join(bundle, 'SHA256SUMS'), 'utf8')).toBe(before);
    expect(readFileSync(sentinel, 'utf8')).toBe('benign-sentinel\n');
  });

  it('verify-only rejects an unlisted extra file without mutating the bundle', () => {
    const root = makeTempRoot();
    const bundle = join(root, 'bundle');
    writeSyntheticBundle(bundle);
    writeFileSync(join(bundle, 'extra-unlisted.txt'), 'extra\n');
    const before = readdirSync(bundle).sort().join('\n');
    const beforeSums = readFileSync(join(bundle, 'SHA256SUMS'), 'utf8');

    const result = runPackage(['--verify-only', bundle]);

    expect(result.status).not.toBe(0);
    expect(result.output).toMatch(
      /SHA256SUMS does not exactly cover|extra-unlisted|omitted|extra files/,
    );
    expect(result.output).not.toMatch(
      /not a native Mach-O|cannot package a non-Mach-O/,
    );
    expect(readdirSync(bundle).sort().join('\n')).toBe(before);
    expect(readFileSync(join(bundle, 'SHA256SUMS'), 'utf8')).toBe(beforeSums);
    expect(readFileSync(join(bundle, 'extra-unlisted.txt'), 'utf8')).toBe(
      'extra\n',
    );
  });

  it('discovers PackageFrameworks/GRDB-dynamic.framework before the non-Mach-O gate', () => {
    expect(packageScript).toContain('PackageFrameworks/GRDB-dynamic.framework');
    expect(packageScript).toContain('Versions/A/GRDB-dynamic');
    const root = makeTempRoot();
    const products = join(root, 'derived/Build/Products/Release');
    mkdirSync(products, { recursive: true });
    writeFileSync(join(products, 'EngramCollector'), 'synthetic-collector\n');
    chmodSync(join(products, 'EngramCollector'), 0o700);
    writeSyntheticCollectorCore(
      join(products, 'EngramCollectorCore.framework'),
    );
    writeSyntheticGRDBDynamic(
      join(products, 'PackageFrameworks/GRDB-dynamic.framework'),
    );

    const result = runPackage(packagingArgs(root));

    expect(result.status).not.toBe(0);
    expect(result.output).not.toMatch(/missing GRDB\.framework/);
  });

  it('rejects a flat-only EngramCollectorCore binary before native Mach-O inspection', () => {
    const root = makeTempRoot();
    const bundle = join(root, 'bundle');
    writeSyntheticBundle(bundle, { omitCore: true });
    mkdirSync(join(bundle, 'Frameworks/EngramCollectorCore.framework'), {
      recursive: true,
    });
    writeFileSync(
      join(
        bundle,
        'Frameworks/EngramCollectorCore.framework/EngramCollectorCore',
      ),
      'synthetic-collector-core\n',
    );
    const files = [
      'BUILD-METADATA.json',
      'bin/EngramCollector',
      'Frameworks/EngramCollectorCore.framework/EngramCollectorCore',
      'Frameworks/GRDB-dynamic.framework/Versions/A/GRDB-dynamic',
      ...collectorTemplateFiles.filter((relative) =>
        existsSync(join(bundle, relative)),
      ),
    ];
    files.sort();
    const sums = files
      .map((relative) => {
        const digest = spawnSync('/usr/bin/shasum', ['-a', '256', relative], {
          cwd: bundle,
          encoding: 'utf8',
        });
        return digest.stdout.trim();
      })
      .join('\n');
    writeFileSync(join(bundle, 'SHA256SUMS'), `${sums}\n`);
    chmodSync(join(bundle, 'SHA256SUMS'), 0o600);
    const before = readdirSync(bundle).sort().join('\n');

    const result = runPackage(['--verify-only', bundle]);

    expect(result.status).not.toBe(0);
    expect(result.output).toMatch(/EngramCollectorCore|Versions\/A|missing/);
    expect(result.output).not.toMatch(
      /not a native Mach-O|cannot package a non-Mach-O/,
    );
    expect(readdirSync(bundle).sort().join('\n')).toBe(before);
  });
});

describe('collector package verify-only symlink prefix bypass', () => {
  it('rejects a bundle/escape symlink to .. before native Mach-O inspection', () => {
    const root = makeTempRoot();
    const bundle = join(root, 'bundle');
    writeSyntheticBundle(bundle);
    symlinkSync('..', join(bundle, 'escape'));
    const before = readdirSync(bundle).sort().join('\n');

    const result = runPackage(['--verify-only', bundle]);

    expect(result.status).not.toBe(0);
    expect(result.output).toMatch(/symlink|escapes package|unsafe path/i);
    expect(result.output).not.toMatch(
      /not a native Mach-O|cannot package a non-Mach-O/,
    );
    expect(readdirSync(bundle).sort().join('\n')).toBe(before);
    expect(lstatSync(join(bundle, 'escape')).isSymbolicLink()).toBe(true);
  });
});

describe('collector package dependency load-path traversal', () => {
  it.each([
    {
      kind: '@rpath',
      loadPath: '@rpath/../../outside-sibling.txt',
    },
    {
      kind: '@executable_path',
      loadPath: '@executable_path/../../outside-sibling.txt',
    },
    {
      kind: '@loader_path',
      loadPath: '@loader_path/../../outside-sibling.txt',
    },
  ])(
    'rejects a $kind traversal suffix to an external sibling file not in the manifest',
    ({ loadPath }) => {
      const root = makeTempRoot();
      const bundle = join(root, 'bundle');
      const probe = join(bundle, 'bin/probe');
      const outside = join(root, 'outside-sibling.txt');
      mkdirSync(join(bundle, 'bin'), { recursive: true });
      mkdirSync(join(bundle, 'Frameworks'), { recursive: true });
      writeFileSync(outside, 'external-not-in-manifest\n');
      writeSyntheticMachOWithLoadDylibs(probe, [loadPath]);
      assertOtoolParsesLoadPath(probe, loadPath);

      const result = runExtractedDependencyClosure(bundle, probe);

      expect(result.status).not.toBe(0);
      expect(result.output).toMatch(
        /unresolved|non-relocatable|escapes|unsafe|outside|traversal|manifest/,
      );
      expect(readFileSync(outside, 'utf8')).toBe('external-not-in-manifest\n');
    },
  );

  it('rejects a /usr/lib prefix-whitelisted traversal load path', () => {
    const root = makeTempRoot();
    const bundle = join(root, 'bundle');
    const probe = join(bundle, 'bin/probe');
    const loadPath =
      '/usr/lib/../../tmp/engram-collector-package-not-in-manifest';
    mkdirSync(join(bundle, 'bin'), { recursive: true });
    writeSyntheticMachOWithLoadDylibs(probe, [loadPath]);
    assertOtoolParsesLoadPath(probe, loadPath);

    const result = runExtractedDependencyClosure(bundle, probe);

    expect(result.status).not.toBe(0);
    expect(result.output).toMatch(
      /usr\/lib|non-relocatable|escapes|unsafe|absolute|traversal/,
    );
  });
});

describe('collector package Versions/A directory alias', () => {
  it('rejects a Versions/A directory alias or still selects both mandatory versioned entities', () => {
    const root = makeTempRoot();
    const bundle = join(root, 'bundle');
    writeSyntheticBundle(bundle);
    const core = join(bundle, 'Frameworks/EngramCollectorCore.framework');
    const grdb = join(bundle, 'Frameworks/GRDB-dynamic.framework');
    aliasVersionDirectoryAToB(core);
    aliasVersionDirectoryAToB(grdb);

    expect(readlinkSync(join(core, 'Versions/Current'))).toBe('A');
    expect(readlinkSync(join(core, 'Versions/A'))).toBe('B');
    expect(readlinkSync(join(grdb, 'Versions/Current'))).toBe('A');
    expect(readlinkSync(join(grdb, 'Versions/A'))).toBe('B');
    expect(
      lstatSync(join(core, 'Versions/B/EngramCollectorCore')).isSymbolicLink(),
    ).toBe(false);
    expect(
      lstatSync(join(grdb, 'Versions/B/GRDB-dynamic')).isSymbolicLink(),
    ).toBe(false);

    const layout = runExtractedLayout(bundle);
    const selected = runShippedNativeFrameworkFind(bundle);
    const hasCore = selected.some((path) =>
      path.endsWith(
        '/EngramCollectorCore.framework/Versions/A/EngramCollectorCore',
      ),
    );
    const hasGrdb = selected.some((path) =>
      path.endsWith('/GRDB-dynamic.framework/Versions/A/GRDB-dynamic'),
    );

    if (layout.status !== 0) {
      expect(layout.output).toMatch(
        /Versions\/A|alias|symlink|missing|entity|directory/,
      );
      expect(layout.output).not.toMatch(
        /not a native Mach-O|cannot package a non-Mach-O/,
      );
    } else {
      expect(hasCore).toBe(true);
      expect(hasGrdb).toBe(true);
    }
  });
});

describe('collector package Frameworks directory alias', () => {
  it('rejects a Frameworks -> RealFrameworks alias or still selects both mandatory versioned entities', () => {
    const root = makeTempRoot();
    const bundle = join(root, 'bundle');
    writeSyntheticBundle(bundle);
    renameSync(join(bundle, 'Frameworks'), join(bundle, 'RealFrameworks'));
    symlinkSync('RealFrameworks', join(bundle, 'Frameworks'));
    writeSha256Sums(bundle, [
      'BUILD-METADATA.json',
      'bin/EngramCollector',
      'RealFrameworks/EngramCollectorCore.framework/Versions/A/EngramCollectorCore',
      'RealFrameworks/GRDB-dynamic.framework/Versions/A/GRDB-dynamic',
    ]);

    expect(readlinkSync(join(bundle, 'Frameworks'))).toBe('RealFrameworks');
    expect(lstatSync(join(bundle, 'Frameworks')).isSymbolicLink()).toBe(true);
    expect(lstatSync(join(bundle, 'RealFrameworks')).isSymbolicLink()).toBe(
      false,
    );

    const layout = runExtractedLayout(bundle);
    const selected = runShippedNativeFrameworkFind(bundle);
    const hasCore = selected.some((path) =>
      path.endsWith(
        '/EngramCollectorCore.framework/Versions/A/EngramCollectorCore',
      ),
    );
    const hasGrdb = selected.some((path) =>
      path.endsWith('/GRDB-dynamic.framework/Versions/A/GRDB-dynamic'),
    );

    if (layout.status !== 0) {
      expect(layout.output).toMatch(
        /Frameworks|alias|symlink|missing|entity|directory/,
      );
      expect(layout.output).not.toMatch(
        /not a native Mach-O|cannot package a non-Mach-O/,
      );
    } else {
      expect(hasCore).toBe(true);
      expect(hasGrdb).toBe(true);
    }
  });
});

describe('collector package extra manifested dependencies', () => {
  it('rejects a manifested extra text dylib that is not a mandatory versioned framework entity', () => {
    const root = makeTempRoot();
    const bundle = join(root, 'bundle');
    const extra = join(bundle, 'Frameworks/extra.dylib');
    const probe = join(bundle, 'bin/probe');
    writeSyntheticBundle(bundle);
    writeFileSync(extra, 'synthetic-extra-text-dylib\n');
    chmodSync(extra, 0o644);
    writeSha256Sums(bundle, [
      'BUILD-METADATA.json',
      'bin/EngramCollector',
      ...mandatoryVersionedEntities,
      'Frameworks/extra.dylib',
    ]);
    writeSyntheticMachOWithLoadDylibs(probe, ['@rpath/extra.dylib']);
    assertOtoolParsesLoadPath(probe, '@rpath/extra.dylib');

    const result = runExtractedDependencyClosure(bundle, probe);

    expect(result.status).not.toBe(0);
    expect(result.output).toMatch(
      /mandatory|versioned|entity|unsafe|allowed|closure|GRDB-dynamic|EngramCollectorCore|extra/,
    );
    expect(readFileSync(extra, 'utf8')).toBe('synthetic-extra-text-dylib\n');
  });

  it('rejects a manifested extra Mach-O with an external transitive dependency', () => {
    const root = makeTempRoot();
    const bundle = join(root, 'bundle');
    const extra = join(bundle, 'Frameworks/extra.dylib');
    const probe = join(bundle, 'bin/probe');
    const external = '/tmp/engram-collector-package-external-transitive.dylib';
    writeSyntheticBundle(bundle);
    writeSyntheticMachOWithLoadDylibs(extra, [external]);
    writeSha256Sums(bundle, [
      'BUILD-METADATA.json',
      'bin/EngramCollector',
      ...mandatoryVersionedEntities,
      'Frameworks/extra.dylib',
    ]);
    writeSyntheticMachOWithLoadDylibs(probe, ['@rpath/extra.dylib']);
    assertOtoolParsesLoadPath(extra, external);
    assertOtoolParsesLoadPath(probe, '@rpath/extra.dylib');

    const result = runExtractedDependencyClosure(bundle, probe);

    expect(result.status).not.toBe(0);
    expect(result.output).toMatch(
      /mandatory|versioned|entity|unsafe|allowed|closure|GRDB-dynamic|EngramCollectorCore|extra|transitive|external/,
    );
    expect(lstatSync(extra).isSymbolicLink()).toBe(false);
  });
});

describe('collector package nested SHA256SUMS exact-set', () => {
  it('rejects an unlisted nested SHA256SUMS at exact-set before native inspection', () => {
    const root = makeTempRoot();
    const bundle = join(root, 'bundle');
    writeSyntheticBundle(bundle);
    mkdirSync(join(bundle, 'notes'), { recursive: true });
    writeFileSync(join(bundle, 'notes/SHA256SUMS'), 'nested-unlisted\n');
    const before = readdirSync(bundle).sort().join('\n');
    const beforeSums = readFileSync(join(bundle, 'SHA256SUMS'), 'utf8');

    const result = runPackage(['--verify-only', bundle]);

    expect(result.status).not.toBe(0);
    expect(result.output).toMatch(
      /SHA256SUMS does not exactly cover|extra-unlisted|omitted|extra files|notes\/SHA256SUMS/,
    );
    expect(result.output).not.toMatch(
      /not a native Mach-O|cannot package a non-Mach-O/,
    );
    expect(readdirSync(bundle).sort().join('\n')).toBe(before);
    expect(readFileSync(join(bundle, 'SHA256SUMS'), 'utf8')).toBe(beforeSums);
    expect(readFileSync(join(bundle, 'notes/SHA256SUMS'), 'utf8')).toBe(
      'nested-unlisted\n',
    );
  });

  it('lets a listed nested SHA256SUMS pass exact-set and reach the synthetic native gate', () => {
    const root = makeTempRoot();
    const bundle = join(root, 'bundle');
    writeSyntheticBundle(bundle);
    mkdirSync(join(bundle, 'notes'), { recursive: true });
    writeFileSync(join(bundle, 'notes/SHA256SUMS'), 'nested-listed\n');
    writeSha256Sums(bundle, [
      'BUILD-METADATA.json',
      'bin/EngramCollector',
      ...mandatoryVersionedEntities,
      'notes/SHA256SUMS',
    ]);
    const beforeSums = readFileSync(join(bundle, 'SHA256SUMS'), 'utf8');

    const result = runPackage(['--verify-only', bundle]);

    expect(result.status).not.toBe(0);
    expect(result.output).not.toMatch(
      /SHA256SUMS does not exactly cover|omitted|extra files/,
    );
    expect(result.output).toMatch(
      /not a native Mach-O|cannot package a non-Mach-O/,
    );
    expect(readFileSync(join(bundle, 'SHA256SUMS'), 'utf8')).toBe(beforeSums);
  });
});

// Task-owned inert stubs only: these are not installer or native-runtime tests.
const collectorTemplateNames = [
  'run-engram-collector.zsh.template',
  'com.engram.collector.plist.template',
] as const;
const collectorTemplateFiles = collectorTemplateNames.map(
  (name) => 'templates/' + name,
);
const collectorTemplateDirectory = join(
  repoRoot,
  'macos/EngramCollector/Packaging',
);

function copyCollectorLaunchTemplates(bundle: string): string[] {
  const copied: string[] = [];
  for (const [index, name] of collectorTemplateNames.entries()) {
    const source = join(collectorTemplateDirectory, name);
    // Existing synthetic rejection fixtures remain valid during RED.
    // New contract tests below require both actual production templates.
    if (!existsSync(source)) continue;
    mkdirSync(join(bundle, 'templates'), { recursive: true, mode: 0o700 });
    const relative = 'templates/' + name;
    writeFileSync(join(bundle, relative), readFileSync(source), {
      mode: index === 0 ? 0o700 : 0o600,
    });
    copied.push(relative);
  }
  return copied;
}

function requireCollectorTemplates(): void {
  for (const name of collectorTemplateNames)
    expect(existsSync(join(collectorTemplateDirectory, name)), name).toBe(true);
}

function collectorLaunchFixture() {
  requireCollectorTemplates();
  const root = makeTempRoot();
  const home = join(root, 'explicit-home');
  const bundle = join(root, 'release');
  mkdirSync(home, { mode: 0o700 });
  mkdirSync(join(home, '.engram'), { mode: 0o700 });
  mkdirSync(join(home, 'Library/LaunchAgents'), {
    recursive: true,
    mode: 0o700,
  });
  writeFileSync(
    join(home, '.engram/settings.json'),
    '{"sentinel":"unchanged"}\n',
    { mode: 0o600 },
  );
  writeFileSync(join(home, '.engram/secret-sentinel'), 'synthetic-only\n', {
    mode: 0o600,
  });
  writeFileSync(
    join(home, 'Library/LaunchAgents/sentinel.plist'),
    'do-not-replace\n',
    { mode: 0o600 },
  );
  symlinkSync('release', join(root, 'current'));
  mkdirSync(join(bundle, 'bin'), { recursive: true, mode: 0o700 });
  const record = join(root, 'exec-record');
  const settingsRecord = join(root, 'settings-record');
  writeFileSync(
    join(bundle, 'bin/EngramCollector'),
    '#!/bin/sh\nprintf \'%s\\0\' "$@" > "$ENGRAM_TEST_EXEC_RECORD"\nprintf \'%s\' "$ENGRAM_SETTINGS_PATH" > "$ENGRAM_TEST_SETTINGS_RECORD"\n',
    { mode: 0o700 },
  );
  const values: Record<string, string> = {
    '--package-root': bundle,
    '--expected-home': home,
    '--settings': join(root, 'settings.json'),
    '--credentials-file': join(root, 'credentials.json'),
  };
  // No FIFO writer: attempting to read either fails the bounded timeout.
  for (const path of [values['--settings'], values['--credentials-file']]) {
    const fifo = spawnSync('/usr/bin/mkfifo', ['-m', '600', path], {
      encoding: 'utf8',
      timeout: 2_000,
    });
    expect(fifo.error).toBeUndefined();
    expect(fifo.status).toBe(0);
  }
  return { root, home, bundle, record, settingsRecord, values };
}

function collectorLaunchSnapshot(directory: string, prefix = ''): string[] {
  return readdirSync(directory)
    .sort()
    .flatMap((name) => {
      const relative = prefix ? prefix + '/' + name : name;
      const path = join(directory, name);
      const info = lstatSync(path);
      const mode = info.mode & 0o7777;
      if (info.isSymbolicLink())
        return ['link ' + mode + ' ' + relative + ' ' + readlinkSync(path)];
      if (info.isDirectory())
        return [
          'dir ' + mode + ' ' + relative,
          ...collectorLaunchSnapshot(path, relative),
        ];
      if (!info.isFile()) return ['special ' + mode + ' ' + relative];
      return [
        'file ' +
          mode +
          ' ' +
          relative +
          ' ' +
          readFileSync(path).toString('base64'),
      ];
    });
}

function runCollectorWrapper(
  fixture: ReturnType<typeof collectorLaunchFixture>,
  args: string[],
) {
  const result = spawnSync(
    '/bin/zsh',
    [join(collectorTemplateDirectory, collectorTemplateNames[0]), ...args],
    {
      cwd: fixture.root,
      encoding: 'utf8',
      timeout: 3_000,
      env: {
        PATH: '/usr/bin:/bin:/usr/sbin:/sbin',
        HOME: fixture.home,
        CFFIXED_USER_HOME: fixture.home,
        TMPDIR: fixture.root,
        LANG: 'C',
        LC_ALL: 'C',
        ENGRAM_TEST_EXEC_RECORD: fixture.record,
        ENGRAM_TEST_SETTINGS_RECORD: fixture.settingsRecord,
      },
    },
  );
  expect(result.error).toBeUndefined();
  expect(result.signal).toBeNull();
  return {
    status: result.status,
    stdout: result.stdout,
    output: result.stdout + result.stderr,
  };
}

function collectorLaunchArgs(values: Record<string, string>): string[] {
  return Object.entries(values).flatMap(([flag, value]) => [flag, value]);
}

function collectorExpectedProductArgs(
  values: Record<string, string>,
): string[] {
  return [
    '--settings',
    values['--settings'],
    '--credentials-file',
    values['--credentials-file'],
  ];
}

describe.skipIf(process.platform !== 'darwin')(
  'Collector launch templates: not installer or native-runtime proof',
  () => {
    it('ships secret-free role templates with launchd disabled by default', () => {
      requireCollectorTemplates();
      const wrapper = readFileSync(
        join(collectorTemplateDirectory, collectorTemplateNames[0]),
        'utf8',
      );
      expect(wrapper).toContain('#!/bin/zsh');
      expect(wrapper).toContain('umask 077');
      expect(wrapper).not.toMatch(/^\s*(?:source|\.)\s+/m);
      expect(wrapper).not.toMatch(/\b(?:launchctl|security|curl|sqlite3)\b/);
      const plist = readFileSync(
        join(collectorTemplateDirectory, collectorTemplateNames[1]),
        'utf8',
      );
      const parsed = spawnSync(
        '/usr/bin/plutil',
        ['-convert', 'json', '-o', '-', '-'],
        {
          input: plist,
          encoding: 'utf8',
          timeout: 2_000,
        },
      );
      expect(parsed.error).toBeUndefined();
      expect(parsed.status).toBe(0);
      const job = JSON.parse(parsed.stdout);
      expect(job.Label).toBe('com.engram.collector');
      expect(job.Disabled).toBe(true);
      expect(job.RunAtLoad).toBe(false);
      expect(job.KeepAlive).toBe(false);
      expect(job.EnvironmentVariables).toBeUndefined();
      expect(job.Program).toBeUndefined();
      expect(job.ProgramArguments).toEqual([
        '__ENGRAM_WRAPPER__',
        '--package-root',
        '__ENGRAM_PACKAGE_ROOT__',
        '--expected-home',
        '__ENGRAM_EXPECTED_HOME__',
        '--settings',
        '__ENGRAM_SETTINGS__',
        '--credentials-file',
        '__ENGRAM_CREDENTIALS__',
      ]);
      expect(plist).not.toMatch(
        /TOKEN|PASSWORD|AT_REST_KEY|legacy-v1\.env|archive-v2\.env/,
      );
    });

    it('XML encoding preserves each special path as one plist argument', () => {
      requireCollectorTemplates();
      const raw = readFileSync(
        join(collectorTemplateDirectory, collectorTemplateNames[1]),
        'utf8',
      );
      const unusual =
        '/fixture/space & <tag> "quote" \'single\' $() \u0060ticks\u0060 \\backslash/路径';
      const escapeXML = (value: string) =>
        value
          .replaceAll('&', '&amp;')
          .replaceAll('<', '&lt;')
          .replaceAll('>', '&gt;')
          .replaceAll('"', '&quot;')
          .replaceAll("'", '&apos;');
      const tokens = [...new Set(raw.match(/__ENGRAM_[A-Z_]+__/g) ?? [])];
      expect(tokens).toHaveLength(5);
      let rendered = raw;
      for (const token of tokens)
        rendered = rendered.replaceAll(token, escapeXML(unusual));
      const parsed = spawnSync(
        '/usr/bin/plutil',
        ['-convert', 'json', '-o', '-', '-'],
        {
          input: rendered,
          encoding: 'utf8',
          timeout: 2_000,
        },
      );
      expect(parsed.error).toBeUndefined();
      expect(parsed.status).toBe(0);
      const args = JSON.parse(parsed.stdout).ProgramArguments as string[];
      expect(args.filter((value) => value === unusual)).toHaveLength(5);
      // Encoding oracle only, not a shipped installation renderer.
    });

    it('dry-run returns exact JSON without reads, exec, installation, or mutation', () => {
      const fixture = collectorLaunchFixture();
      const before = collectorLaunchSnapshot(fixture.root);
      const result = runCollectorWrapper(fixture, [
        '--dry-run',
        ...collectorLaunchArgs(fixture.values),
      ]);
      expect(result.status).toBe(0);
      expect(JSON.parse(result.stdout)).toEqual({
        kind: 'launch-plan',
        role: 'collector',
        executable: join(fixture.bundle, 'bin/EngramCollector'),
        arguments: collectorExpectedProductArgs(fixture.values),
        environment: {},
        expectedHome: fixture.home,
        installs: false,
        executes: false,
      });
      expect(collectorLaunchSnapshot(fixture.root)).toEqual(before);
      expect(existsSync(fixture.record)).toBe(false);
      expect(existsSync(fixture.settingsRecord)).toBe(false);
    });

    it('preserves shell, JSON, XML, Unicode and control characters in dry-run paths', () => {
      const fixture = collectorLaunchFixture();
      const suffix =
        '/space \' " & < > $() \u0060ticks\u0060 \\backslash\tline\nreturn\r路径';
      const values = Object.fromEntries(
        Object.entries(fixture.values).map(([flag, path]) => [
          flag,
          path + suffix,
        ]),
      );
      const before = collectorLaunchSnapshot(fixture.root);
      const result = runCollectorWrapper(fixture, [
        '--dry-run',
        ...collectorLaunchArgs(values),
      ]);
      expect(result.status).toBe(0);
      const plan = JSON.parse(result.stdout);
      expect(plan.executable).toBe(
        values['--package-root'] + '/bin/EngramCollector',
      );
      expect(plan.arguments).toEqual(collectorExpectedProductArgs(values));
      expect(plan.expectedHome).toBe(values['--expected-home']);
      expect(plan.environment).toEqual({});
      expect(collectorLaunchSnapshot(fixture.root)).toEqual(before);
    });

    it.each([
      '--package-root',
      '--expected-home',
      '--settings',
      '--credentials-file',
    ])('requires %s exactly once with an absolute resolved path', (flag) => {
      const fixture = collectorLaunchFixture();
      const without = Object.entries(fixture.values)
        .filter(([key]) => key !== flag)
        .flatMap(([key, value]) => [key, value]);
      const valid = collectorLaunchArgs(fixture.values);
      const cases = [
        ['--dry-run', ...without],
        ['--dry-run', ...without, flag],
        ['--dry-run', ...valid, flag, fixture.values[flag]],
        ...[
          'relative',
          '',
          '/__ENGRAM_UNRESOLVED__',
          '/fixture/../escape',
          '/fixture//alias',
          '/fixture/./alias',
        ].map((value) => ['--dry-run', ...without, flag, value]),
      ];
      const before = collectorLaunchSnapshot(fixture.root);
      for (const args of cases) {
        const result = runCollectorWrapper(fixture, args);
        expect(result.status, JSON.stringify(args)).not.toBe(0);
        expect(result.output).toMatch(
          /invalid|required|missing|duplicate|absolute|placeholder|unresolved|usage/i,
        );
        expect(existsSync(fixture.record)).toBe(false);
        expect(collectorLaunchSnapshot(fixture.root)).toEqual(before);
      }
    });

    it.each([['--unknown'], ['--dry-run', '--dry-run'], ['--once'], ['--']])(
      'rejects unsupported or duplicate switches %j before exec',
      (...extra) => {
        const fixture = collectorLaunchFixture();
        const before = collectorLaunchSnapshot(fixture.root);
        const result = runCollectorWrapper(fixture, [
          ...extra,
          ...collectorLaunchArgs(fixture.values),
        ]);
        expect(result.status).not.toBe(0);
        expect(collectorLaunchSnapshot(fixture.root)).toEqual(before);
      },
    );

    it('does not evaluate special path text during real launch through the inert stub', () => {
      const fixture = collectorLaunchFixture();
      const values = { ...fixture.values };
      const injection =
        '/literal \' " & < > $(touch injected-marker) \u0060touch injected-marker\u0060 \\suffix\tline\n路径';
      for (const flag of Object.keys(values)) {
        if (flag !== '--package-root') values[flag] += injection;
      }
      const before = collectorLaunchSnapshot(fixture.root);
      const result = runCollectorWrapper(fixture, collectorLaunchArgs(values));
      expect(result.status).toBe(0);
      expect(
        readFileSync(fixture.record, 'utf8').split('\0').slice(0, -1),
      ).toEqual(collectorExpectedProductArgs(values));
      expect(existsSync(join(fixture.root, 'injected-marker'))).toBe(false);
      const after = collectorLaunchSnapshot(fixture.root).filter(
        (line) => !/^file [0-9]+ (?:exec-record|settings-record) /.test(line),
      );
      expect(after).toEqual(before);
    });

    it('maps real-launch arguments using only an inert fixture executable', () => {
      const fixture = collectorLaunchFixture();
      const result = runCollectorWrapper(
        fixture,
        collectorLaunchArgs(fixture.values),
      );
      expect(result.status).toBe(0);
      expect(
        readFileSync(fixture.record, 'utf8').split('\0').slice(0, -1),
      ).toEqual(collectorExpectedProductArgs(fixture.values));
      expect(readFileSync(fixture.settingsRecord, 'utf8')).toBe('');
      expect(lstatSync(fixture.values['--settings']).isFIFO()).toBe(true);
      expect(lstatSync(fixture.values['--credentials-file']).isFIFO()).toBe(
        true,
      );
      // expectedHome does not set HOME or create a sandbox. Service checks its
      // actual home; Collector receives no unsupported expected-home CLI flag.
    });
  },
);

describe('Collector package launch-template integrity', () => {
  it('adds both deployment templates to the package plan without installing anything', () => {
    requireCollectorTemplates();
    const root = makeTempRoot();
    const before = collectorLaunchSnapshot(root);
    const result = runPackage(['--dry-run', ...packagingArgs(root)]);
    expect(result.status).toBe(0);
    for (const relative of collectorTemplateFiles)
      expect(result.output).toContain(relative);
    expect(collectorLaunchSnapshot(root)).toEqual(before);
  });

  it('accepts exact owner-only manifested templates up to the synthetic native rejection', () => {
    requireCollectorTemplates();
    const root = makeTempRoot();
    const bundle = makeCollectorLaunchBundle(root);
    const manifest = readFileSync(join(bundle, 'SHA256SUMS'), 'utf8');
    for (const [index, relative] of collectorTemplateFiles.entries()) {
      expect(readFileSync(join(bundle, relative))).toEqual(
        readFileSync(
          join(collectorTemplateDirectory, collectorTemplateNames[index]),
        ),
      );
      expect(lstatSync(join(bundle, relative)).mode & 0o777).toBe(
        index === 0 ? 0o700 : 0o600,
      );
      expect(manifest).toContain('  ' + relative + '\n');
    }
    const before = collectorLaunchSnapshot(root);
    const result = runPackage(['--verify-only', bundle]);
    expect(result.status).not.toBe(0);
    expect(result.output).toMatch(/not (?:a )?native Mach-O|non-Mach-O/i);
    expect(result.output).not.toMatch(
      /template|alias|mode|exactly cover|verification failed/i,
    );
    expect(collectorLaunchSnapshot(root)).toEqual(before);
  });

  it.each(collectorTemplateFiles)(
    'rejects missing, wrong-mode, aliased, modified or unlisted %s before native inspection',
    (relative) => {
      requireCollectorTemplates();
      for (const mutation of [
        'missing',
        'mode',
        'alias',
        'content',
        'unlisted',
      ] as const) {
        const root = makeTempRoot();
        const bundle = makeCollectorLaunchBundle(root);
        const target = join(bundle, relative);
        if (mutation === 'missing') rmSync(target);
        if (mutation === 'mode')
          chmodSync(target, relative.endsWith('.zsh.template') ? 0o600 : 0o644);
        if (mutation === 'alias') {
          renameSync(target, target + '.saved');
          symlinkSync(target + '.saved', target);
        }
        if (mutation === 'content') {
          // A valid shell/XML comment proves recomputed hashes alone are not
          // enough: verifier must compare against its trusted role templates.
          writeFileSync(
            target,
            readFileSync(target, 'utf8') +
              (relative.endsWith('.zsh.template')
                ? '\n# changed launch contract\n'
                : '\n<!-- changed launch contract -->\n'),
          );
        }
        if (mutation === 'unlisted') {
          const lines = readFileSync(join(bundle, 'SHA256SUMS'), 'utf8').split(
            '\n',
          );
          writeFileSync(
            join(bundle, 'SHA256SUMS'),
            lines.filter((line) => !line.endsWith('  ' + relative)).join('\n'),
          );
        } else {
          writeSha256Sums(
            bundle,
            collectorLaunchRegularFiles(bundle).filter(
              (path) => path !== 'SHA256SUMS',
            ),
          );
        }
        if (mutation === 'alias') {
          const manifest = readFileSync(join(bundle, 'SHA256SUMS'), 'utf8');
          expect(manifest).not.toContain('  ' + relative + '\n');
          expect(manifest).toContain('  ' + relative + '.saved\n');
        }
        const before = collectorLaunchSnapshot(root);
        const result = runPackage(['--verify-only', bundle]);
        expect(result.status, mutation).not.toBe(0);
        if (mutation === 'alias') {
          expect(result.output).toMatch(/alias|symlink|regular|template/i);
          expect(result.output).not.toMatch(
            /exactly cover|verification failed/i,
          );
        }
        expect(result.output).toMatch(
          /template|required|missing|alias|symlink|mode|0700|0600|700|600|SHA256SUMS|exactly cover|manifest/i,
        );
        expect(result.output).not.toMatch(
          /not (?:a )?native Mach-O|non-Mach-O/i,
        );
        expect(collectorLaunchSnapshot(root)).toEqual(before);
      }
    },
  );

  it('rejects an internally aliased templates directory instead of trusting its resolved contents', () => {
    requireCollectorTemplates();
    const root = makeTempRoot();
    const bundle = makeCollectorLaunchBundle(root);
    renameSync(join(bundle, 'templates'), join(bundle, 'saved-templates'));
    symlinkSync('saved-templates', join(bundle, 'templates'));
    writeSha256Sums(
      bundle,
      collectorLaunchRegularFiles(bundle).filter(
        (path) => path !== 'SHA256SUMS',
      ),
    );
    const manifest = readFileSync(join(bundle, 'SHA256SUMS'), 'utf8');
    for (const name of collectorTemplateNames) {
      expect(manifest).not.toContain('  templates/' + name + '\n');
      expect(manifest).toContain('  saved-templates/' + name + '\n');
    }
    const before = collectorLaunchSnapshot(root);
    const result = runPackage(['--verify-only', bundle]);
    expect(result.status).not.toBe(0);
    expect(result.output).toMatch(/templates|alias|symlink|directory/i);
    expect(result.output).not.toMatch(/exactly cover|verification failed/i);
    expect(result.output).not.toMatch(/not (?:a )?native Mach-O|non-Mach-O/i);
    expect(collectorLaunchSnapshot(root)).toEqual(before);
  });
});

function makeCollectorLaunchBundle(root: string): string {
  const bundle = join(root, 'bundle');
  writeSyntheticBundle(bundle);
  return bundle;
}

function collectorLaunchRegularFiles(directory: string, prefix = ''): string[] {
  return readdirSync(directory)
    .sort()
    .flatMap((name) => {
      const path = join(directory, name);
      const relative = prefix ? prefix + '/' + name : name;
      const info = lstatSync(path);
      if (info.isSymbolicLink()) return [];
      if (info.isDirectory())
        return collectorLaunchRegularFiles(path, relative);
      return info.isFile() ? [relative] : [];
    });
}

describe('Collector source-template preflight before output mutation', () => {
  it.each(
    [
      { target: 'wrapper', mutation: 'missing' },
      { target: 'plist', mutation: 'missing' },
      { target: 'directory', mutation: 'missing' },
      { target: 'wrapper', mutation: 'alias' },
      { target: 'plist', mutation: 'alias' },
      { target: 'directory', mutation: 'alias' },
      { target: 'role-parent', mutation: 'alias' },
    ].flatMap((entry) =>
      [false, true].map((existingOutput) => ({ ...entry, existingOutput })),
    ),
  )(
    'rejects $mutation source $target before changing output (existing=$existingOutput)',
    ({ target, mutation, existingOutput }) => {
      requireCollectorTemplates();
      const root = makeTempRoot();
      const macos = join(root, 'source-tree/macos');
      const scriptDirectory = join(macos, 'scripts');
      const sourceTemplates = join(macos, 'EngramCollector/Packaging');
      mkdirSync(scriptDirectory, { recursive: true, mode: 0o700 });
      mkdirSync(sourceTemplates, { recursive: true, mode: 0o700 });
      const copiedScript = join(scriptDirectory, 'package-collector.sh');
      const shippedScript = readFileSync(packageScriptPath);
      writeFileSync(copiedScript, shippedScript, { mode: 0o700 });
      expect(readFileSync(copiedScript)).toEqual(shippedScript);
      for (const [index, name] of collectorTemplateNames.entries()) {
        writeFileSync(
          join(sourceTemplates, name),
          readFileSync(join(collectorTemplateDirectory, name)),
          { mode: index === 0 ? 0o700 : 0o600 },
        );
      }

      // Host-native inert bytes remove an earlier "text is not Mach-O" failure
      // on macOS. Only copies are inspected; this helper is never executed,
      // and these are not a valid role package or dependency-closure fixture.
      const nativeBytes = readFileSync('/usr/bin/true');
      expect(nativeBytes.length).toBeGreaterThan(0);
      const products = join(root, 'derived/Build/Products/Release');
      mkdirSync(products, { recursive: true, mode: 0o700 });
      writeFileSync(join(products, 'EngramCollector'), nativeBytes, {
        mode: 0o700,
      });
      for (const name of ['EngramCollectorCore', 'GRDB-dynamic']) {
        const parent =
          name === 'GRDB-dynamic'
            ? join(products, 'PackageFrameworks')
            : products;
        const framework = join(parent, name + '.framework');
        writeSyntheticVersionedFramework(
          framework,
          name,
          'inert-native-placeholder',
        );
        writeFileSync(join(framework, 'Versions/A', name), nativeBytes);
      }

      const affected =
        target === 'role-parent'
          ? join(macos, 'EngramCollector')
          : target === 'directory'
            ? sourceTemplates
            : join(
                sourceTemplates,
                collectorTemplateNames[target === 'wrapper' ? 0 : 1],
              );
      if (mutation === 'missing')
        rmSync(affected, { recursive: target === 'directory' });
      else {
        const saved =
          target === 'role-parent'
            ? join(root, 'external-role-source')
            : affected + '.saved';
        renameSync(affected, saved);
        symlinkSync(saved, affected);
        expect(lstatSync(affected).isSymbolicLink()).toBe(true);
        if (target === 'role-parent') {
          // The Packaging directory and leaves are regular: only their role
          // parent aliases outside the synthetic macos source tree.
          expect(lstatSync(sourceTemplates).isDirectory()).toBe(true);
          expect(lstatSync(sourceTemplates).isSymbolicLink()).toBe(false);
          for (const name of collectorTemplateNames) {
            const leaf = lstatSync(join(sourceTemplates, name));
            expect(leaf.isFile()).toBe(true);
            expect(leaf.isSymbolicLink()).toBe(false);
          }
        }
      }
      if (existingOutput) mkdirSync(join(root, 'output'), { mode: 0o700 });
      const before = collectorLaunchSnapshot(root);
      const result = spawnSync(
        '/bin/bash',
        [copiedScript, ...packagingArgs(root)],
        {
          cwd: root,
          encoding: 'utf8',
          timeout: 10_000,
          env: {
            PATH: '/usr/bin:/bin:/usr/sbin:/sbin',
            HOME: root,
            CFFIXED_USER_HOME: root,
            TMPDIR: root,
            LANG: 'C',
            LC_ALL: 'C',
          },
        },
      );
      expect(result.error).toBeUndefined();
      expect(result.signal).toBeNull();
      const output = result.stdout + result.stderr;
      expect(result.status).not.toBe(0);
      expect(output).toMatch(/template|Packaging/i);
      expect(output).toMatch(
        mutation === 'missing'
          ? /missing|required|regular/i
          : /alias|symlink|regular|directory/i,
      );
      expect(output).not.toMatch(
        /not (?:a )?native Mach-O|non-Mach-O|command not found/i,
      );
      expect(existsSync(join(root, 'output'))).toBe(existingOutput);
      if (existingOutput) expect(readdirSync(join(root, 'output'))).toEqual([]);
      expect(collectorLaunchSnapshot(root)).toEqual(before);
      expect(readFileSync(copiedScript)).toEqual(shippedScript);
    },
  );
});
