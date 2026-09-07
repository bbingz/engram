import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
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
import { join, resolve } from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';

const repoRoot = resolve(import.meta.dirname, '../..');
const packageScriptPath = join(repoRoot, 'macos/scripts/package-service.sh');
const revision = 'a'.repeat(40);
const frameworks = [
  'EngramServiceCore',
  'EngramCoreRead',
  'EngramCoreWrite',
  'GRDB-dynamic',
] as const;
const nonNativeError = /(?:not (?:a )?native Mach-O|non-Mach-O)/i;
let tempRoots: string[] = [];

afterEach(() => {
  for (const root of tempRoots) rmSync(root, { recursive: true, force: true });
  tempRoots = [];
});

function makeRoot(): string {
  const root = mkdtempSync(join(repoRoot, '.engram-service-package-test-'));
  tempRoots.push(root);
  for (const name of ['home', 'tmp']) {
    mkdirSync(join(root, name), { mode: 0o700 });
  }
  return root;
}

function runPackage(root: string, args: string[]) {
  const result = spawnSync('/bin/bash', [packageScriptPath, ...args], {
    cwd: root,
    encoding: 'utf8',
    timeout: 10_000,
    env: {
      PATH: '/usr/bin:/bin:/usr/sbin:/sbin',
      HOME: join(root, 'home'),
      CFFIXED_USER_HOME: join(root, 'home'),
      TMPDIR: join(root, 'tmp'),
      LANG: 'C',
      LC_ALL: 'C',
    },
  });
  expect(result.error).toBeUndefined();
  expect(result.signal).toBeNull();
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

function withArgument(root: string, flag: string, value: string): string[] {
  const args = packagingArgs(root);
  args[args.indexOf(flag) + 1] = value;
  return args;
}

function regularFiles(directory: string, prefix = ''): string[] {
  return readdirSync(directory)
    .sort()
    .flatMap((name) => {
      const relative = prefix ? `${prefix}/${name}` : name;
      const absolute = join(directory, name);
      const stat = lstatSync(absolute);
      if (stat.isSymbolicLink()) return [];
      if (stat.isDirectory()) return regularFiles(absolute, relative);
      return stat.isFile() ? [relative] : [];
    });
}

function digest(path: string): string {
  return createHash('sha256').update(readFileSync(path)).digest('hex');
}

// Do not follow aliases while checking that verification left the entire
// fixture unchanged. Access times are deliberately excluded from read-only QA.
function snapshot(directory: string, prefix = ''): string[] {
  return readdirSync(directory)
    .sort()
    .flatMap((name) => {
      const relative = prefix ? `${prefix}/${name}` : name;
      const absolute = join(directory, name);
      const stat = lstatSync(absolute);
      const mode = (stat.mode & 0o7777).toString(8);
      if (stat.isSymbolicLink()) {
        return [`link ${mode} ${relative} -> ${readlinkSync(absolute)}`];
      }
      if (stat.isDirectory()) {
        return [`dir ${mode} ${relative}`, ...snapshot(absolute, relative)];
      }
      return [`file ${mode} ${relative} ${digest(absolute)}`];
    });
}

function writeManifest(bundle: string): void {
  const lines = regularFiles(bundle)
    .filter((path) => path !== 'SHA256SUMS')
    .sort()
    .map((path) => `${digest(join(bundle, path))}  ${path}`);
  writeFileSync(join(bundle, 'SHA256SUMS'), `${lines.join('\n')}\n`, {
    mode: 0o600,
  });
}

function writeFramework(parent: string, name: string): string {
  const framework = join(parent, `${name}.framework`);
  const version = join(framework, 'Versions/A');
  mkdirSync(version, { recursive: true, mode: 0o700 });
  writeFileSync(join(version, name), `synthetic-${name}\n`, { mode: 0o700 });
  symlinkSync('A', join(framework, 'Versions/Current'));
  symlinkSync(`Versions/Current/${name}`, join(framework, name));
  return framework;
}

function writeBundle(root: string): string {
  const bundle = join(root, 'bundle');
  mkdirSync(join(bundle, 'bin'), { recursive: true, mode: 0o700 });
  writeFileSync(
    join(bundle, 'bin/EngramService'),
    'synthetic-service-not-executable-code\n',
    { mode: 0o700 },
  );
  for (const name of frameworks)
    writeFramework(join(bundle, 'Frameworks'), name);
  writeFileSync(
    join(bundle, 'BUILD-METADATA.json'),
    `${JSON.stringify(
      {
        schemaVersion: 1,
        product: 'EngramService',
        role: 'index',
        configuration: 'Release',
        architecture: 'arm64',
        sourceRevision: revision,
      },
      null,
      2,
    )}\n`,
    { mode: 0o600 },
  );
  copyServiceLaunchTemplates(bundle);
  writeManifest(bundle);
  return bundle;
}

function rejectUnchanged(root: string, bundle: string, reason: RegExp): void {
  const before = snapshot(root);
  const result = runPackage(root, ['--verify-only', bundle]);
  expect(result.status).not.toBe(0);
  expect(result.output).toMatch(reason);
  expect(result.output).not.toMatch(nonNativeError);
  expect(snapshot(root)).toEqual(before);
}

describe('Service role package public command contract', () => {
  it('provides an independent Service packager beside the existing role packagers', () => {
    expect(existsSync(packageScriptPath)).toBe(true);
  });

  it.each([
    { name: 'missing arguments', args: () => [], reason: /usage:|required/i },
    {
      name: 'unknown flag',
      args: () => ['--unknown'],
      reason: /unknown argument/i,
    },
    {
      name: 'missing option value',
      args: () => ['--derived-data'],
      reason: /missing value/i,
    },
    {
      name: 'relative derived data',
      args: (root: string) => withArgument(root, '--derived-data', 'relative'),
      reason: /absolute/i,
    },
    {
      name: 'relative output',
      args: (root: string) => withArgument(root, '--output', 'relative'),
      reason: /absolute/i,
    },
    {
      name: 'Debug configuration',
      args: (root: string) => withArgument(root, '--configuration', 'Debug'),
      reason: /Release/,
    },
    {
      name: 'wrong architecture',
      args: (root: string) => withArgument(root, '--arch', 'x86_64'),
      reason: /arm64/,
    },
    {
      name: 'short source revision',
      args: (root: string) =>
        withArgument(root, '--source-revision', 'a'.repeat(39)),
      reason: /40|revision|commit/i,
    },
    {
      name: 'nonhex source revision',
      args: (root: string) =>
        withArgument(root, '--source-revision', 'z'.repeat(40)),
      reason: /hex|revision|commit/i,
    },
    {
      name: 'duplicate source revision',
      args: (root: string) => [
        ...packagingArgs(root),
        '--source-revision',
        revision,
      ],
      reason: /duplicate/i,
    },
    {
      name: 'mixed verification and packaging',
      args: (root: string) => [
        '--verify-only',
        join(root, 'bundle'),
        '--arch',
        'arm64',
      ],
      reason: /cannot be combined/i,
    },
    {
      name: 'mixed verification and dry-run',
      args: (root: string) => [
        '--verify-only',
        join(root, 'bundle'),
        '--dry-run',
      ],
      reason: /cannot be combined/i,
    },
  ])('rejects $name before any fixture mutation', ({ args, reason }) => {
    const root = makeRoot();
    const before = snapshot(root);
    const result = runPackage(root, args(root));
    expect(result.status).not.toBe(0);
    expect(result.output).toMatch(reason);
    expect(snapshot(root)).toEqual(before);
  });

  it('rejects a nonempty output and preserves existing bytes', () => {
    const root = makeRoot();
    mkdirSync(join(root, 'output'));
    writeFileSync(join(root, 'output/keep'), 'do not replace\n');
    const before = snapshot(root);
    const result = runPackage(root, packagingArgs(root));
    expect(result.status).not.toBe(0);
    expect(result.output).toMatch(/new or empty|non.?empty/i);
    expect(snapshot(root)).toEqual(before);
  });

  it('rejects an output symlink without following or changing its target', () => {
    const root = makeRoot();
    mkdirSync(join(root, 'target'));
    writeFileSync(join(root, 'target/keep'), 'private sentinel\n');
    symlinkSync('target', join(root, 'output'));
    const before = snapshot(root);
    const result = runPackage(root, packagingArgs(root));
    expect(result.status).not.toBe(0);
    expect(result.output).toMatch(/symlink|alias/i);
    expect(snapshot(root)).toEqual(before);
  });

  it.each([false, true])(
    'dry-run leaves an existing empty output=%s and all private state unchanged',
    (existingOutput) => {
      const root = makeRoot();
      const home = join(root, 'home');
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
      writeFileSync(
        join(home, '.engram/synthetic-secret'),
        'not-a-real-secret\n',
        { mode: 0o600 },
      );
      writeFileSync(
        join(home, 'Library/LaunchAgents/sentinel.plist'),
        'do not replace\n',
        { mode: 0o600 },
      );
      if (existingOutput) mkdirSync(join(root, 'output'), { mode: 0o700 });
      const before = snapshot(root);
      const result = runPackage(root, ['--dry-run', ...packagingArgs(root)]);
      expect(result.status).toBe(0);
      expect(result.output).toMatch(/dry-run/);
      expect(result.output).toContain('EngramService');
      expect(result.output).toMatch(/role[=: ]+index/);
      expect(existsSync(join(root, 'output'))).toBe(existingOutput);
      expect(snapshot(root)).toEqual(before);
    },
  );
});

describe('Service package synthetic rejection gates, not native package proof', () => {
  it.each(frameworks)('rejects missing %s before native inspection', (name) => {
    const root = makeRoot();
    const bundle = writeBundle(root);
    rmSync(join(bundle, `Frameworks/${name}.framework`), { recursive: true });
    writeManifest(bundle);
    rejectUnchanged(root, bundle, new RegExp(`${name}|missing`, 'i'));
  });

  it.each(frameworks)(
    'rejects mismatched %s bytes against the exact manifest',
    (name) => {
      const root = makeRoot();
      const bundle = writeBundle(root);
      writeFileSync(
        join(bundle, `Frameworks/${name}.framework/Versions/A/${name}`),
        'changed after manifest\n',
      );
      rejectUnchanged(root, bundle, /SHA256SUMS|mismatch|verification failed/i);
    },
  );

  it('rejects an omitted manifest member even when all listed hashes match', () => {
    const root = makeRoot();
    const bundle = writeBundle(root);
    const manifest = join(bundle, 'SHA256SUMS');
    writeFileSync(
      manifest,
      readFileSync(manifest, 'utf8')
        .split('\n')
        .filter((line) => !line.includes('EngramCoreRead.framework'))
        .join('\n'),
    );
    rejectUnchanged(root, bundle, /exactly cover|manifest|SHA256SUMS|omitted/i);
  });

  it('rejects an unlisted extra regular file', () => {
    const root = makeRoot();
    const bundle = writeBundle(root);
    writeFileSync(join(bundle, 'unlisted.txt'), 'extra\n');
    rejectUnchanged(root, bundle, /exactly cover|manifest|SHA256SUMS|extra/i);
  });

  it('rejects duplicate manifest entries', () => {
    const root = makeRoot();
    const bundle = writeBundle(root);
    const manifest = join(bundle, 'SHA256SUMS');
    const contents = readFileSync(manifest, 'utf8');
    writeFileSync(manifest, `${contents}${contents.split('\n')[0]}\n`);
    rejectUnchanged(root, bundle, /duplicate|manifest|SHA256SUMS/i);
  });

  it.each([
    ['product', 'EngramCollector'],
    ['role', 'collector'],
    ['configuration', 'Debug'],
    ['architecture', 'x86_64'],
    ['sourceRevision', 'b'.repeat(39)],
  ])('rejects rehashed metadata with incorrect %s', (key, value) => {
    const root = makeRoot();
    const bundle = writeBundle(root);
    const path = join(bundle, 'BUILD-METADATA.json');
    const metadata = JSON.parse(readFileSync(path, 'utf8'));
    metadata[key] = value;
    writeFileSync(path, `${JSON.stringify(metadata)}\n`);
    writeManifest(bundle);
    rejectUnchanged(
      root,
      bundle,
      /metadata|role|product|configuration|architecture|revision/i,
    );
  });

  it.each(['parent traversal', 'absolute'])(
    'rejects unsafe manifest path %s before hashing it',
    (kind) => {
      const root = makeRoot();
      const bundle = writeBundle(root);
      writeFileSync(
        join(root, 'outside-sentinel'),
        'outside package sentinel\n',
        { mode: 0o600 },
      );
      const path =
        kind === 'absolute'
          ? join(root, 'outside-sentinel')
          : '../outside-sentinel';
      writeFileSync(join(bundle, 'SHA256SUMS'), `${'c'.repeat(64)}  ${path}\n`);
      rejectUnchanged(
        root,
        bundle,
        /unsafe manifest|escapes package|unsafe path/i,
      );
    },
  );

  it('rejects a symlink to the parent directory without following it', () => {
    const root = makeRoot();
    const bundle = writeBundle(root);
    symlinkSync('..', join(bundle, 'escape'));
    rejectUnchanged(root, bundle, /symlink|escape|unsafe path/i);
  });

  it('rejects an escaping framework entity and preserves its external sentinel', () => {
    const root = makeRoot();
    const bundle = writeBundle(root);
    const entity = join(
      bundle,
      'Frameworks/EngramServiceCore.framework/Versions/A/EngramServiceCore',
    );
    rmSync(entity);
    writeFileSync(
      join(root, 'outside-sentinel'),
      'outside package sentinel\n',
      { mode: 0o600 },
    );
    symlinkSync(join(root, 'outside-sentinel'), entity);
    writeManifest(bundle);
    rejectUnchanged(root, bundle, /symlink|alias|escape|regular|entity/i);
  });

  it('rejects an aliased Frameworks directory that would evade a no-follow native scan', () => {
    const root = makeRoot();
    const bundle = writeBundle(root);
    renameSync(join(bundle, 'Frameworks'), join(bundle, 'RealFrameworks'));
    symlinkSync('RealFrameworks', join(bundle, 'Frameworks'));
    writeManifest(bundle);
    rejectUnchanged(root, bundle, /Frameworks|symlink|alias/i);
  });

  it.each(frameworks)(
    'rejects %s Versions/A as an alias to another version',
    (name) => {
      const root = makeRoot();
      const bundle = writeBundle(root);
      const versions = join(bundle, `Frameworks/${name}.framework/Versions`);
      renameSync(join(versions, 'A'), join(versions, 'B'));
      symlinkSync('B', join(versions, 'A'));
      writeManifest(bundle);
      rejectUnchanged(root, bundle, /Versions\/A|symlink|alias|directory/i);
    },
  );

  it.each(frameworks)(
    'rejects flat-only %s instead of accepting a missing Version A entity',
    (name) => {
      const root = makeRoot();
      const bundle = writeBundle(root);
      const framework = join(bundle, `Frameworks/${name}.framework`);
      rmSync(join(framework, 'Versions'), { recursive: true });
      rmSync(join(framework, name));
      writeFileSync(join(framework, name), 'flat synthetic framework\n', {
        mode: 0o700,
      });
      writeManifest(bundle);
      rejectUnchanged(
        root,
        bundle,
        new RegExp(`${name}|Versions/A|missing`, 'i'),
      );
    },
  );

  it.each([
    'Engram.app',
    'EngramMCP',
    'EngramCollector',
    'EngramRemoteServer',
    'node',
    'node_modules',
    'dist',
    'daemon.js',
    'index.js',
    'web.js',
  ])(
    'rejects forbidden role entry %s even with a matching manifest',
    (name) => {
      const root = makeRoot();
      const bundle = writeBundle(root);
      writeFileSync(
        join(bundle, 'bin', name),
        'forbidden synthetic role entry\n',
      );
      writeManifest(bundle);
      rejectUnchanged(root, bundle, /forbidden|unexpected|not allowed|role/i);
    },
  );

  it('rejects a bare helper package rather than treating it as deployable', () => {
    const root = makeRoot();
    const bundle = writeBundle(root);
    rmSync(join(bundle, 'Frameworks'), { recursive: true });
    writeManifest(bundle);
    rejectUnchanged(root, bundle, /Frameworks|framework|missing/i);
  });

  it.skipIf(process.platform !== 'darwin')(
    'reaches the native gate with a complete synthetic layout but never accepts fake Mach-O',
    () => {
      const root = makeRoot();
      const bundle = writeBundle(root);
      const before = snapshot(root);
      const result = runPackage(root, ['--verify-only', bundle]);
      expect(result.status).not.toBe(0);
      expect(result.output).toMatch(nonNativeError);
      expect(result.output).not.toMatch(/package-service: PASS/);
      expect(snapshot(root)).toEqual(before);
    },
  );

  it('contains actual native verification signals without claiming these fixtures verify native closure', () => {
    const source = existsSync(packageScriptPath)
      ? readFileSync(packageScriptPath, 'utf8')
      : '';
    expect(source).toMatch(/otool/);
    expect(source).toMatch(/codesign[^\n]*--verify/);
    expect(source).toMatch(/lipo/);
    expect(source).toContain('@executable_path/../Frameworks');
    expect(source).not.toContain('launchctl');
    expect(source).not.toContain('Library/LaunchAgents');
  });
});

describe('Service package exact-set and build-source preflight regressions', () => {
  it('rejects an unlisted nested SHA256SUMS before native inspection', () => {
    const root = makeRoot();
    const bundle = writeBundle(root);
    const resources = join(
      bundle,
      'Frameworks/EngramServiceCore.framework/Versions/A/Resources',
    );
    mkdirSync(resources, { mode: 0o700 });
    writeFileSync(
      join(resources, 'SHA256SUMS'),
      'nested resource must be accounted for\n',
      { mode: 0o600 },
    );
    rejectUnchanged(root, bundle, /exactly cover|manifest|SHA256SUMS|extra/i);
  });

  it.skipIf(process.platform !== 'darwin')(
    'accounts for a correctly listed nested SHA256SUMS and reaches the native rejection gate',
    () => {
      const root = makeRoot();
      const bundle = writeBundle(root);
      const relative =
        'Frameworks/EngramServiceCore.framework/Versions/A/Resources/SHA256SUMS';
      mkdirSync(
        join(
          bundle,
          'Frameworks/EngramServiceCore.framework/Versions/A/Resources',
        ),
        { mode: 0o700 },
      );
      writeFileSync(
        join(bundle, relative),
        'nested resource must be accounted for\n',
        { mode: 0o600 },
      );
      writeManifest(bundle);
      expect(readFileSync(join(bundle, 'SHA256SUMS'), 'utf8')).toContain(
        `  ${relative}\n`,
      );
      const before = snapshot(root);
      const result = runPackage(root, ['--verify-only', bundle]);
      expect(result.status).not.toBe(0);
      expect(result.output).toMatch(nonNativeError);
      expect(result.output).not.toMatch(
        /exactly cover|verification failed|package-service: PASS/i,
      );
      expect(snapshot(root)).toEqual(before);
    },
  );

  it.each(['EngramService', ...frameworks])(
    'rejects missing build source %s before changing sources or an existing empty output',
    (name) => {
      const root = makeRoot();
      const products = writeSyntheticServiceBuildSources(root);
      const missing =
        name === 'EngramService'
          ? join(products, name)
          : name === 'GRDB-dynamic'
            ? join(products, 'PackageFrameworks/GRDB-dynamic.framework')
            : join(products, `${name}.framework`);
      rmSync(missing, { recursive: true });
      mkdirSync(join(root, 'output'), { mode: 0o700 });
      const before = snapshot(root);
      const result = runPackage(root, packagingArgs(root));
      expect(result.status).not.toBe(0);
      expect(result.output).toContain(name);
      expect(result.output).toMatch(/missing|regular Release executable/i);
      expect(result.output).not.toMatch(nonNativeError);
      expect(readdirSync(join(root, 'output'))).toEqual([]);
      expect(snapshot(root)).toEqual(before);
    },
  );

  it('rejects a root-level GRDB fallback when PackageFrameworks is missing without creating output', () => {
    const root = makeRoot();
    const products = writeSyntheticServiceBuildSources(root);
    rmSync(join(products, 'PackageFrameworks/GRDB-dynamic.framework'), {
      recursive: true,
    });
    writeFramework(products, 'GRDB-dynamic');
    const before = snapshot(root);
    const result = runPackage(root, packagingArgs(root));
    expect(result.status).not.toBe(0);
    expect(result.output).toContain('PackageFrameworks/GRDB-dynamic.framework');
    expect(result.output).toMatch(/missing/i);
    expect(result.output).not.toMatch(nonNativeError);
    expect(existsSync(join(root, 'output'))).toBe(false);
    expect(snapshot(root)).toEqual(before);
  });

  it('finds GRDB only in PackageFrameworks and rejects the synthetic executable before creating output', () => {
    const root = makeRoot();
    const products = writeSyntheticServiceBuildSources(root);
    expect(existsSync(join(products, 'GRDB-dynamic.framework'))).toBe(false);
    const before = snapshot(root);
    const result = runPackage(root, packagingArgs(root));
    expect(result.status).not.toBe(0);
    expect(result.output).toMatch(nonNativeError);
    expect(result.output).toContain('EngramService');
    expect(result.output).not.toMatch(/missing|package-service: PASS/i);
    expect(existsSync(join(root, 'output'))).toBe(false);
    expect(snapshot(root)).toEqual(before);
  });
});

function writeSyntheticServiceBuildSources(root: string): string {
  const products = join(root, 'derived/Build/Products/Release');
  mkdirSync(products, { recursive: true, mode: 0o700 });
  writeFileSync(
    join(products, 'EngramService'),
    'synthetic-build-source-not-executable-code\n',
    { mode: 0o700 },
  );
  for (const name of frameworks) {
    writeFramework(
      name === 'GRDB-dynamic' ? join(products, 'PackageFrameworks') : products,
      name,
    );
  }
  return products;
}

// Task-owned inert stubs only: these are not installer or native-runtime tests.
const serviceTemplateNames = [
  'run-engram-service-index.zsh.template',
  'com.engram.service-index.plist.template',
] as const;
const serviceTemplateFiles = serviceTemplateNames.map(
  (name) => 'templates/' + name,
);
const serviceTemplateDirectory = join(
  repoRoot,
  'macos/EngramService/Packaging',
);

function copyServiceLaunchTemplates(bundle: string): string[] {
  const copied: string[] = [];
  for (const [index, name] of serviceTemplateNames.entries()) {
    const source = join(serviceTemplateDirectory, name);
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

function requireServiceTemplates(): void {
  for (const name of serviceTemplateNames)
    expect(existsSync(join(serviceTemplateDirectory, name)), name).toBe(true);
}

function serviceLaunchFixture() {
  requireServiceTemplates();
  const root = makeRoot();
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
    join(bundle, 'bin/EngramService'),
    '#!/bin/sh\nprintf \'%s\\0\' "$@" > "$ENGRAM_TEST_EXEC_RECORD"\nprintf \'%s\' "$ENGRAM_SETTINGS_PATH" > "$ENGRAM_TEST_SETTINGS_RECORD"\n',
    { mode: 0o700 },
  );
  const values: Record<string, string> = {
    '--package-root': bundle,
    '--expected-home': home,
    '--settings': join(root, 'settings.json'),
    '--credentials-file': join(root, 'credentials.json'),
    '--database-path': join(root, 'index/index.sqlite'),
    '--service-socket': join(root, 'run/service.sock'),
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

function serviceLaunchSnapshot(directory: string, prefix = ''): string[] {
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
          ...serviceLaunchSnapshot(path, relative),
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

function runServiceWrapper(
  fixture: ReturnType<typeof serviceLaunchFixture>,
  args: string[],
) {
  const result = spawnSync(
    '/bin/zsh',
    [join(serviceTemplateDirectory, serviceTemplateNames[0]), ...args],
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

function serviceLaunchArgs(values: Record<string, string>): string[] {
  return Object.entries(values).flatMap(([flag, value]) => [flag, value]);
}

function serviceExpectedProductArgs(values: Record<string, string>): string[] {
  return [
    '--expected-home',
    values['--expected-home'],
    '--database-path',
    values['--database-path'],
    '--service-socket',
    values['--service-socket'],
    '--capture-credentials-file',
    values['--credentials-file'],
  ];
}

describe.skipIf(process.platform !== 'darwin')(
  'Service launch templates: not installer or native-runtime proof',
  () => {
    it('ships secret-free role templates with launchd disabled by default', () => {
      requireServiceTemplates();
      const wrapper = readFileSync(
        join(serviceTemplateDirectory, serviceTemplateNames[0]),
        'utf8',
      );
      expect(wrapper).toContain('#!/bin/zsh');
      expect(wrapper).toContain('umask 077');
      expect(wrapper).not.toMatch(/^\s*(?:source|\.)\s+/m);
      expect(wrapper).not.toMatch(/\b(?:launchctl|security|curl|sqlite3)\b/);
      const plist = readFileSync(
        join(serviceTemplateDirectory, serviceTemplateNames[1]),
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
      expect(job.Label).toBe('com.engram.service-index');
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
        '--database-path',
        '__ENGRAM_DATABASE_PATH__',
        '--service-socket',
        '__ENGRAM_SERVICE_SOCKET__',
      ]);
      expect(plist).not.toMatch(
        /TOKEN|PASSWORD|AT_REST_KEY|legacy-v1\.env|archive-v2\.env/,
      );
    });

    it('XML encoding preserves each special path as one plist argument', () => {
      requireServiceTemplates();
      const raw = readFileSync(
        join(serviceTemplateDirectory, serviceTemplateNames[1]),
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
      expect(tokens).toHaveLength(7);
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
      expect(args.filter((value) => value === unusual)).toHaveLength(7);
      // Encoding oracle only, not a shipped installation renderer.
    });

    it('dry-run returns exact JSON without reads, exec, installation, or mutation', () => {
      const fixture = serviceLaunchFixture();
      const before = serviceLaunchSnapshot(fixture.root);
      const result = runServiceWrapper(fixture, [
        '--dry-run',
        ...serviceLaunchArgs(fixture.values),
      ]);
      expect(result.status).toBe(0);
      expect(JSON.parse(result.stdout)).toEqual({
        kind: 'launch-plan',
        role: 'index',
        executable: join(fixture.bundle, 'bin/EngramService'),
        arguments: serviceExpectedProductArgs(fixture.values),
        environment: { ENGRAM_SETTINGS_PATH: fixture.values['--settings'] },
        expectedHome: fixture.home,
        installs: false,
        executes: false,
      });
      expect(serviceLaunchSnapshot(fixture.root)).toEqual(before);
      expect(existsSync(fixture.record)).toBe(false);
      expect(existsSync(fixture.settingsRecord)).toBe(false);
    });

    it('preserves shell, JSON, XML, Unicode and control characters in dry-run paths', () => {
      const fixture = serviceLaunchFixture();
      const suffix =
        '/space \' " & < > $() \u0060ticks\u0060 \\backslash\tline\nreturn\r路径';
      const values = Object.fromEntries(
        Object.entries(fixture.values).map(([flag, path]) => [
          flag,
          path + suffix,
        ]),
      );
      const before = serviceLaunchSnapshot(fixture.root);
      const result = runServiceWrapper(fixture, [
        '--dry-run',
        ...serviceLaunchArgs(values),
      ]);
      expect(result.status).toBe(0);
      const plan = JSON.parse(result.stdout);
      expect(plan.executable).toBe(
        values['--package-root'] + '/bin/EngramService',
      );
      expect(plan.arguments).toEqual(serviceExpectedProductArgs(values));
      expect(plan.expectedHome).toBe(values['--expected-home']);
      expect(plan.environment).toEqual({
        ENGRAM_SETTINGS_PATH: values['--settings'],
      });
      expect(serviceLaunchSnapshot(fixture.root)).toEqual(before);
    });

    it.each([
      '--package-root',
      '--expected-home',
      '--settings',
      '--credentials-file',
      '--database-path',
      '--service-socket',
    ])('requires %s exactly once with an absolute resolved path', (flag) => {
      const fixture = serviceLaunchFixture();
      const without = Object.entries(fixture.values)
        .filter(([key]) => key !== flag)
        .flatMap(([key, value]) => [key, value]);
      const valid = serviceLaunchArgs(fixture.values);
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
      const before = serviceLaunchSnapshot(fixture.root);
      for (const args of cases) {
        const result = runServiceWrapper(fixture, args);
        expect(result.status, JSON.stringify(args)).not.toBe(0);
        expect(result.output).toMatch(
          /invalid|required|missing|duplicate|absolute|placeholder|unresolved|usage/i,
        );
        expect(existsSync(fixture.record)).toBe(false);
        expect(serviceLaunchSnapshot(fixture.root)).toEqual(before);
      }
    });

    it.each([['--unknown'], ['--dry-run', '--dry-run'], ['--once'], ['--']])(
      'rejects unsupported or duplicate switches %j before exec',
      (...extra) => {
        const fixture = serviceLaunchFixture();
        const before = serviceLaunchSnapshot(fixture.root);
        const result = runServiceWrapper(fixture, [
          ...extra,
          ...serviceLaunchArgs(fixture.values),
        ]);
        expect(result.status).not.toBe(0);
        expect(serviceLaunchSnapshot(fixture.root)).toEqual(before);
      },
    );

    it('does not evaluate special path text during real launch through the inert stub', () => {
      const fixture = serviceLaunchFixture();
      const values = { ...fixture.values };
      const injection =
        '/literal \' " & < > $(touch injected-marker) \u0060touch injected-marker\u0060 \\suffix\tline\n路径';
      for (const flag of Object.keys(values)) {
        if (flag !== '--package-root') values[flag] += injection;
      }
      const before = serviceLaunchSnapshot(fixture.root);
      const result = runServiceWrapper(fixture, serviceLaunchArgs(values));
      expect(result.status).toBe(0);
      expect(
        readFileSync(fixture.record, 'utf8').split('\0').slice(0, -1),
      ).toEqual(serviceExpectedProductArgs(values));
      expect(existsSync(join(fixture.root, 'injected-marker'))).toBe(false);
      const after = serviceLaunchSnapshot(fixture.root).filter(
        (line) => !/^file [0-9]+ (?:exec-record|settings-record) /.test(line),
      );
      expect(after).toEqual(before);
    });

    it('maps real-launch arguments using only an inert fixture executable', () => {
      const fixture = serviceLaunchFixture();
      const result = runServiceWrapper(
        fixture,
        serviceLaunchArgs(fixture.values),
      );
      expect(result.status).toBe(0);
      expect(
        readFileSync(fixture.record, 'utf8').split('\0').slice(0, -1),
      ).toEqual(serviceExpectedProductArgs(fixture.values));
      expect(readFileSync(fixture.settingsRecord, 'utf8')).toBe(
        fixture.values['--settings'],
      );
      expect(lstatSync(fixture.values['--settings']).isFIFO()).toBe(true);
      expect(lstatSync(fixture.values['--credentials-file']).isFIFO()).toBe(
        true,
      );
      // expectedHome does not set HOME or create a sandbox. Service checks its
      // actual home; Collector receives no unsupported expected-home CLI flag.
    });
  },
);

describe('Service package launch-template integrity', () => {
  it('adds both deployment templates to the package plan without installing anything', () => {
    requireServiceTemplates();
    const root = makeRoot();
    const before = serviceLaunchSnapshot(root);
    const result = runPackage(root, ['--dry-run', ...packagingArgs(root)]);
    expect(result.status).toBe(0);
    for (const relative of serviceTemplateFiles)
      expect(result.output).toContain(relative);
    expect(serviceLaunchSnapshot(root)).toEqual(before);
  });

  it.skipIf(process.platform !== 'darwin')(
    'accepts exact owner-only manifested templates up to the synthetic native rejection',
    () => {
      requireServiceTemplates();
      const root = makeRoot();
      const bundle = writeBundle(root);
      const manifest = readFileSync(join(bundle, 'SHA256SUMS'), 'utf8');
      for (const [index, relative] of serviceTemplateFiles.entries()) {
        expect(readFileSync(join(bundle, relative))).toEqual(
          readFileSync(
            join(serviceTemplateDirectory, serviceTemplateNames[index]),
          ),
        );
        expect(lstatSync(join(bundle, relative)).mode & 0o777).toBe(
          index === 0 ? 0o700 : 0o600,
        );
        expect(manifest).toContain('  ' + relative + '\n');
      }
      const before = serviceLaunchSnapshot(root);
      const result = runPackage(root, ['--verify-only', bundle]);
      expect(result.status).not.toBe(0);
      expect(result.output).toMatch(/not (?:a )?native Mach-O|non-Mach-O/i);
      expect(result.output).not.toMatch(
        /template|alias|mode|exactly cover|verification failed/i,
      );
      expect(serviceLaunchSnapshot(root)).toEqual(before);
    },
  );

  it.each(serviceTemplateFiles)(
    'rejects missing, wrong-mode, aliased, modified or unlisted %s before native inspection',
    (relative) => {
      requireServiceTemplates();
      for (const mutation of [
        'missing',
        'mode',
        'alias',
        'content',
        'unlisted',
      ] as const) {
        const root = makeRoot();
        const bundle = writeBundle(root);
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
          writeManifest(bundle);
        }
        if (mutation === 'alias') {
          const manifest = readFileSync(join(bundle, 'SHA256SUMS'), 'utf8');
          expect(manifest).not.toContain('  ' + relative + '\n');
          expect(manifest).toContain('  ' + relative + '.saved\n');
        }
        const before = serviceLaunchSnapshot(root);
        const result = runPackage(root, ['--verify-only', bundle]);
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
        expect(serviceLaunchSnapshot(root)).toEqual(before);
      }
    },
  );

  it('rejects an internally aliased templates directory instead of trusting its resolved contents', () => {
    requireServiceTemplates();
    const root = makeRoot();
    const bundle = writeBundle(root);
    renameSync(join(bundle, 'templates'), join(bundle, 'saved-templates'));
    symlinkSync('saved-templates', join(bundle, 'templates'));
    writeManifest(bundle);
    const manifest = readFileSync(join(bundle, 'SHA256SUMS'), 'utf8');
    for (const name of serviceTemplateNames) {
      expect(manifest).not.toContain('  templates/' + name + '\n');
      expect(manifest).toContain('  saved-templates/' + name + '\n');
    }
    const before = serviceLaunchSnapshot(root);
    const result = runPackage(root, ['--verify-only', bundle]);
    expect(result.status).not.toBe(0);
    expect(result.output).toMatch(/templates|alias|symlink|directory/i);
    expect(result.output).not.toMatch(/exactly cover|verification failed/i);
    expect(result.output).not.toMatch(/not (?:a )?native Mach-O|non-Mach-O/i);
    expect(serviceLaunchSnapshot(root)).toEqual(before);
  });
});

describe('Service source-template preflight before output mutation', () => {
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
      requireServiceTemplates();
      const root = makeRoot();
      const macos = join(root, 'source-tree/macos');
      const scriptDirectory = join(macos, 'scripts');
      const sourceTemplates = join(macos, 'EngramService/Packaging');
      mkdirSync(scriptDirectory, { recursive: true, mode: 0o700 });
      mkdirSync(sourceTemplates, { recursive: true, mode: 0o700 });
      const copiedScript = join(scriptDirectory, 'package-service.sh');
      const shippedScript = readFileSync(packageScriptPath);
      writeFileSync(copiedScript, shippedScript, { mode: 0o700 });
      expect(readFileSync(copiedScript)).toEqual(shippedScript);
      for (const [index, name] of serviceTemplateNames.entries()) {
        writeFileSync(
          join(sourceTemplates, name),
          readFileSync(join(serviceTemplateDirectory, name)),
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
      writeFileSync(join(products, 'EngramService'), nativeBytes, {
        mode: 0o700,
      });
      for (const name of frameworks) {
        const parent =
          name === 'GRDB-dynamic'
            ? join(products, 'PackageFrameworks')
            : products;
        const framework = join(parent, name + '.framework');
        writeFramework(parent, name);
        writeFileSync(join(framework, 'Versions/A', name), nativeBytes);
      }

      const affected =
        target === 'role-parent'
          ? join(macos, 'EngramService')
          : target === 'directory'
            ? sourceTemplates
            : join(
                sourceTemplates,
                serviceTemplateNames[target === 'wrapper' ? 0 : 1],
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
          for (const name of serviceTemplateNames) {
            const leaf = lstatSync(join(sourceTemplates, name));
            expect(leaf.isFile()).toBe(true);
            expect(leaf.isSymbolicLink()).toBe(false);
          }
        }
      }
      if (existingOutput) mkdirSync(join(root, 'output'), { mode: 0o700 });
      const before = serviceLaunchSnapshot(root);
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
      expect(serviceLaunchSnapshot(root)).toEqual(before);
      expect(readFileSync(copiedScript)).toEqual(shippedScript);
    },
  );
});
