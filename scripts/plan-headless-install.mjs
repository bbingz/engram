#!/usr/bin/env node
// Repository-only installation planning. Never bundled or used to start a role.
// This script writes nothing and runs no launchctl mutation. It reads host
// metadata (lstat, readlink, one read-only launchd label probe) and the
// credential IDs of an owner-only credentials file; it never prints credential
// values. Applying a printed plan is scripts/apply-headless-install.mjs, which
// accepts only a plan whose canonical hash matches (design §4.6, D12).
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { lstatSync, readdirSync, readFileSync, readlinkSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export const roles = {
  collector: {
    product: 'EngramCollector',
    label: 'com.engram.collector',
    wrapper: 'run-engram-collector.zsh',
    verifier: 'package-collector.sh',
  },
  'service-index': {
    product: 'EngramService',
    label: 'com.engram.service-index',
    wrapper: 'run-engram-service-index.zsh',
    verifier: 'package-service.sh',
  },
  'remote-server': {
    product: 'EngramRemoteServer',
    label: 'com.engram.remote-server',
    wrapper: 'run-engram-remote.zsh',
    verifier: 'package-remote-server.sh',
  },
};
const kinds = ['install', 'upgrade', 'rollback'];
const common = ['role', 'install-root', 'launch-agent-directory'];
// package is required unless the plan kind is rollback.
const optionalCommon = ['package', 'kind', 'launchctl', 'verifier-directory'];
const capture = [
  'expected-home',
  'settings',
  'credentials-file',
  'credential-ids',
];
const collector = ['identity-catalog'];
const index = ['database-path', 'service-socket'];
const optionalIndex = ['capture-source-authority-file'];
const remote = ['legacy-env-file', 'archive-env-file'];
const optionalRemote = ['web-env-file'];
const switches = ['dry-run', 'assert-no-identity-catalog'];
const nonPath = new Set(['role', 'kind', 'credential-ids']);
// Optional launch agent slots: a null binding drops the flag and its value.
export const optionalSlots = {
  __ENGRAM_CAPTURE_SOURCE_AUTHORITY__: '--capture-source-authority-file',
};

export function fail(message) {
  throw new Error(message);
}
export function overlaps(a, b) {
  return a === b || a.startsWith(`${b}/`) || b.startsWith(`${a}/`);
}
export function statIfPresent(path) {
  try {
    return lstatSync(path);
  } catch (error) {
    if (error.code === 'ENOENT') return null;
    throw error;
  }
}
export function digestFile(file) {
  return createHash('sha256').update(readFileSync(file)).digest('hex');
}
// linkLeaf allows the named path itself to be a symlink (current, rollback).
export function path(value, linkLeaf = false) {
  if (
    typeof value !== 'string' ||
    !value.startsWith('/') ||
    value === '/' ||
    Buffer.byteLength(value) > 4096 ||
    /[\x00-\x1f\x7f]/.test(value) ||
    value.includes('__ENGRAM_') ||
    value
      .slice(1)
      .split('/')
      .some(
        (component) => !component || component === '.' || component === '..',
      )
  ) {
    fail('invalid absolute path or unresolved placeholder');
  }
  // Check only the explicitly named path and its parents; no directory scans.
  for (let current = value; current !== '/'; current = dirname(current)) {
    if (linkLeaf && current === value) continue;
    if (statIfPresent(current)?.isSymbolicLink())
      fail('path has a symlink alias');
  }
  return value;
}
export function identifier(value) {
  return /^[A-Za-z0-9._-]{1,128}$/.test(value);
}
function canonical(value) {
  if (Array.isArray(value)) return `[${value.map(canonical).join(',')}]`;
  if (value && typeof value === 'object')
    return `{${Object.keys(value)
      .sort()
      .map((key) => `${JSON.stringify(key)}:${canonical(value[key])}`)
      .join(',')}}`;
  return JSON.stringify(value);
}
// The hash the executor requires covers every field except the hash itself.
export function canonicalPlanHash(plan) {
  const { planHash: _ignored, ...rest } = plan;
  return createHash('sha256').update(canonical(rest)).digest('hex');
}

export function parseArguments(argv) {
  const values = {};
  const flags = {};
  const known = new Set([
    ...common,
    ...optionalCommon,
    ...capture,
    ...collector,
    ...index,
    ...optionalIndex,
    ...remote,
    ...optionalRemote,
  ]);
  for (let i = 0; i < argv.length; i++) {
    const flag = argv[i];
    const key = flag.startsWith('--') ? flag.slice(2) : '';
    if (switches.includes(key)) {
      if (flags[key]) fail(`duplicate --${key}`);
      flags[key] = true;
      continue;
    }
    if (!known.has(key))
      fail('unknown option; only explicit --dry-run is supported');
    if (Object.hasOwn(values, key)) fail('duplicate option');
    if (++i >= argv.length || argv[i].startsWith('--'))
      fail('missing option value');
    values[key] = argv[i];
  }
  if (!flags['dry-run'])
    fail('explicit --dry-run is required; apply is a separate executor');
  if (!Object.hasOwn(roles, values.role)) fail('unknown role');
  const kind = values.kind ?? 'install';
  if (!kinds.includes(kind)) fail('unknown plan kind');
  values.kind = kind;
  const required = [
    ...common,
    ...(kind === 'rollback' ? [] : ['package']),
    ...(values.role === 'remote-server' ? remote : capture),
    ...(values.role === 'collector' ? collector : []),
    ...(values.role === 'service-index' ? index : []),
  ];
  const allowed = [
    ...required,
    ...optionalCommon.filter((key) => key !== 'package' || kind !== 'rollback'),
    ...(values.role === 'service-index' ? optionalIndex : []),
    ...(values.role === 'remote-server' ? optionalRemote : []),
  ];
  if (required.some((key) => !Object.hasOwn(values, key)))
    fail('missing required option');
  if (Object.keys(values).some((key) => !allowed.includes(key)))
    fail('unexpected cross-role option');
  if (flags['assert-no-identity-catalog']) {
    if (values.role !== 'collector' || kind !== 'install')
      fail('--assert-no-identity-catalog applies only to a collector install');
    values['assert-no-identity-catalog'] = true;
  }
  if (Object.hasOwn(values, 'credential-ids')) {
    const ids = values['credential-ids'].split(',');
    if (
      ids.length < 1 ||
      !ids.every(identifier) ||
      new Set(ids).size !== ids.length
    )
      fail('credential IDs must be distinct identifiers');
  }
  for (const key of Object.keys(values)) {
    if (!nonPath.has(key) && key !== 'assert-no-identity-catalog')
      path(values[key]);
  }
  return values;
}

export function validatePackageTemplates(options) {
  const role = roles[options.role];
  const directory = join(options.package, 'templates');
  path(directory);
  if (!statIfPresent(directory)?.isDirectory())
    fail('required package templates directory missing');
  for (const name of [
    `${role.wrapper}.template`,
    `${role.label}.plist.template`,
  ]) {
    const template = join(directory, name);
    path(template);
    if (!statIfPresent(template)?.isFile())
      fail('required package template missing or not regular');
  }
}

// Reports only owner/mode/regular-file facts and the presence of expected IDs.
// Values are parsed to find the keys and are never returned or printed.
export function inspectCredentials(file, expectedIDs) {
  const info = statIfPresent(file);
  if (!info) return { file, expectedIDs, status: 'absent' };
  if (
    !info.isFile() ||
    info.uid !== process.getuid() ||
    (info.mode & 0o7777) !== 0o600 ||
    info.nlink !== 1 ||
    info.size > 64 * 1024
  )
    fail('credentials file must be an owner-only 0600 regular file');
  let map;
  try {
    map = JSON.parse(readFileSync(file, 'utf8'));
  } catch {
    fail('credentials file is not a JSON object of string values');
  }
  if (
    !map ||
    typeof map !== 'object' ||
    Array.isArray(map) ||
    Object.values(map).some((value) => typeof value !== 'string')
  )
    fail('credentials file is not a JSON object of string values');
  for (const id of expectedIDs)
    if (!Object.hasOwn(map, id))
      fail(`credentials file lacks credential ID ${id}`);
  return { file, expectedIDs, status: 'verified' };
}

// Plan --initialize against an existing catalog; plan --initialize-identity
// only when the owner asserts there is none. Anything else is ambiguous.
function inspectIdentityCatalog(catalog, asserted, kind) {
  const info = statIfPresent(catalog);
  const sidecars = ['-wal', '-shm'].filter((suffix) =>
    statIfPresent(catalog + suffix),
  );
  if (info?.isFile()) {
    if (asserted) fail('owner asserted no identity catalog but one exists');
    return { catalog, status: 'existing' };
  }
  if (info) fail('identity catalog path is not a regular file');
  if (sidecars.length)
    fail('identity catalog is missing but its SQLite sidecars exist');
  if (kind !== 'install') fail(`identity catalog must exist for ${kind}`);
  if (!asserted)
    fail(
      'no identity catalog found; pass --assert-no-identity-catalog only after confirming this host never had one',
    );
  if (!catalog.endsWith('/archive.sqlite'))
    fail('a new identity catalog must be named archive.sqlite');
  return { catalog, status: 'new' };
}

export function launchAgentKeys(text) {
  const once = (key) => {
    const matches = text.match(new RegExp(`<key>${key}</key>`, 'g')) ?? [];
    if (matches.length > 1) fail(`launch agent template repeats ${key}`);
    return matches.length === 1;
  };
  const boolean = (key) => {
    if (!once(key)) return null;
    const match = new RegExp(`<key>${key}</key>\\s*<(true|false)/>`).exec(text);
    if (!match) fail(`launch agent template ${key} is not a boolean`);
    return match[1] === 'true';
  };
  const label = once('Label')
    ? /<key>Label<\/key>\s*<string>([^<]+)<\/string>/.exec(text)?.[1]
    : null;
  if (!label) fail('launch agent template lacks a Label');
  return {
    label,
    disabled: boolean('Disabled'),
    runAtLoad: boolean('RunAtLoad'),
    keepAlive: boolean('KeepAlive'),
  };
}

function symlinkTarget(link, releases) {
  const info = statIfPresent(link);
  if (!info) return null;
  if (!info.isSymbolicLink()) fail(`${link} is not a symlink`);
  const target = readlinkSync(link);
  if (
    !target.startsWith(`${releases}/`) ||
    !statIfPresent(target)?.isDirectory()
  )
    fail(`${link} does not point at an installed release`);
  return target;
}

export function makeInstallationPlan(options, metadata, host = {}) {
  const role = roles[options.role];
  if (!role || metadata.product !== role.product)
    fail('package product does not match role');
  if (!/^[0-9a-f]{40}$/.test(metadata.sourceRevision ?? ''))
    fail('invalid source revision');
  const kind = options.kind ?? 'install';
  const root = options['install-root'];
  const releases = join(root, 'releases');
  const release = join(releases, metadata.sourceRevision);
  const current = join(root, 'current');
  const targets = {
    release,
    current,
    wrapper: join(root, role.wrapper),
    launchAgent: join(options['launch-agent-directory'], `${role.label}.plist`),
    rollbackPointer: join(root, 'rollback'),
  };
  if (options.package && overlaps(root, options.package))
    fail('installation root overlaps package');
  if (
    overlaps(root, options['launch-agent-directory']) ||
    (options.package &&
      overlaps(options.package, options['launch-agent-directory']))
  )
    fail('job directory overlaps package or installation root');
  for (const [name, target] of Object.entries(targets))
    path(target, name === 'current' || name === 'rollbackPointer');
  let previousRelease = null;
  let previousPointer = null;
  if (kind === 'install') {
    for (const target of Object.values(targets)) {
      if (statIfPresent(target))
        fail(
          'existing target would be overwritten; a separate upgrade transaction is required',
        );
    }
  } else {
    previousRelease = symlinkTarget(current, releases);
    if (!previousRelease) fail(`${kind} requires an existing current release`);
    previousPointer = symlinkTarget(targets.rollbackPointer, releases);
    for (const target of [targets.wrapper, targets.launchAgent]) {
      const info = statIfPresent(target);
      if (info ? !info.isFile() : kind === 'rollback')
        fail(`${kind} requires regular wrapper and launch agent targets`);
    }
    if (kind === 'upgrade') {
      if (statIfPresent(release))
        fail('release already installed; upgrade needs a new revision');
      if (previousRelease === release)
        fail('current already points at this release');
    } else {
      if (!previousPointer) fail('rollback requires a rollback pointer');
      if (previousPointer !== release)
        fail('rollback metadata does not match the rollback pointer');
      if (previousRelease === release)
        fail('current already points at the rollback release');
    }
  }
  const templateRoot = kind === 'rollback' ? release : options.package;
  const expectedHome = options['expected-home'];
  if (
    expectedHome &&
    [
      releases,
      current,
      targets.wrapper,
      ...(options.package ? [options.package] : []),
      options['launch-agent-directory'],
    ].some(
      (target) =>
        expectedHome === target || expectedHome.startsWith(`${target}/`),
    )
  ) {
    fail('user home is inside a package or installation target');
  }
  // expected-home describes the user context; it is not a writable state file.
  for (const key of [
    'settings',
    'credentials-file',
    'identity-catalog',
    'capture-source-authority-file',
    ...index,
  ]) {
    const value = options[key];
    if (
      value &&
      (overlaps(value, releases) ||
        overlaps(value, current) ||
        overlaps(value, targets.wrapper) ||
        (options.package && overlaps(value, options.package)) ||
        overlaps(value, options['launch-agent-directory']))
    )
      fail('state path overlaps release/current/package/job target');
  }
  if (
    options.role === 'service-index' &&
    overlaps(
      dirname(options['database-path']),
      dirname(options['service-socket']),
    )
  ) {
    fail('database and socket parents must be independent');
  }
  if (
    options.role === 'remote-server' &&
    (options['legacy-env-file'] !== join(root, 'secrets/legacy-v1.env') ||
      options['archive-env-file'] !== join(root, 'secrets/archive-v2.env') ||
      (options['web-env-file'] &&
        options['web-env-file'] !== join(root, 'secrets/web.env')))
  )
    fail('remote secret locations must match the existing wrapper contract');
  const identity =
    options.role === 'collector'
      ? inspectIdentityCatalog(
          options['identity-catalog'],
          Boolean(options['assert-no-identity-catalog']),
          kind,
        )
      : null;
  const credentials =
    options.role === 'remote-server'
      ? null
      : inspectCredentials(
          options['credentials-file'],
          options['credential-ids'].split(','),
        );
  const launchAgentTemplate = join(
    templateRoot,
    'templates',
    `${role.label}.plist.template`,
  );
  if (!statIfPresent(launchAgentTemplate)?.isFile())
    fail('launch agent template missing from the release');
  const keys = launchAgentKeys(readFileSync(launchAgentTemplate, 'utf8'));
  if (keys.label !== role.label)
    fail('launch agent template label does not match role');
  const domain = `gui/${process.getuid()}`;
  const launchd = host.launchd ?? 'NOT_PROBED';
  if (launchd !== 'NOT_PROBED' && launchd.loaded) {
    if (launchd.path !== targets.launchAgent || kind === 'install')
      fail('launch agent label is already loaded by a different job');
  }
  const service = `${domain}/${role.label}`;
  const commands = [
    ...(launchd !== 'NOT_PROBED' && launchd.loaded
      ? [['bootout', service]]
      : []),
    ...(keys.disabled === true ? [['enable', service]] : []),
    ['bootstrap', domain, targets.launchAgent],
    ...(keys.runAtLoad === true ? [] : [['kickstart', '-k', service]]),
  ];
  const inputs = Object.fromEntries(
    Object.entries(options).map(([key, value]) => [
      key.replace(/-([a-z])/g, (_, letter) => letter.toUpperCase()),
      value,
    ]),
  );
  const executable = join(release, 'bin/EngramCollector');
  const initialize =
    options.role === 'collector' && kind === 'install'
      ? [
          ...(identity.status === 'new'
            ? [
                {
                  operation: 'initialize-collector-identity',
                  executable,
                  arguments: ['--initialize-identity', identity.catalog],
                  overwrite: false,
                  startsCollection: false,
                },
              ]
            : []),
          {
            operation: 'initialize-collector-spool',
            executable,
            arguments: ['--settings', options.settings, '--initialize'],
            overwrite: false,
            startsCollection: false,
          },
        ]
      : [];
  const overwrite = kind !== 'install';
  return {
    kind: `${kind === 'install' ? 'installation' : kind}-dry-run`,
    transaction: kind,
    role: options.role,
    product: metadata.product,
    sourceRevision: metadata.sourceRevision,
    previousRelease,
    packageVerified: false,
    inputs,
    targets,
    identity,
    credentials: credentials && {
      ...credentials,
      ownerOnly: credentials.status === 'verified',
    },
    activation: {
      disabled: keys.disabled,
      runAtLoad: keys.runAtLoad,
      keepAlive: keys.keepAlive,
      label: role.label,
      domain,
      launchd,
      launchctl: 'NOT_RUN',
      commands,
    },
    steps: [
      ...(kind === 'rollback'
        ? [
            {
              operation: 'verify-existing-release',
              script: role.verifier,
              bundle: release,
            },
          ]
        : [
            {
              operation: 'copy-new-release',
              source: options.package,
              destination: release,
              overwrite: false,
            },
            {
              operation: 'verify-copied-release',
              script: role.verifier,
              bundle: release,
            },
          ]),
      ...initialize,
      {
        operation: 'render-wrapper',
        template: join(release, 'templates', `${role.wrapper}.template`),
        destination: targets.wrapper,
        bindings:
          options.role === 'remote-server'
            ? {
                __ENGRAM_REMOTE_ROOT__: root,
                __ENGRAM_REMOTE_SOURCE_REVISION__: metadata.sourceRevision,
              }
            : {},
        mode: '0700',
        overwrite,
      },
      {
        operation: 'render-launch-agent',
        template: join(release, 'templates', `${role.label}.plist.template`),
        destination: targets.launchAgent,
        label: role.label,
        wrapper: targets.wrapper,
        bindings:
          options.role === 'remote-server'
            ? { __ENGRAM_REMOTE_WRAPPER__: targets.wrapper }
            : {
                __ENGRAM_WRAPPER__: targets.wrapper,
                __ENGRAM_PACKAGE_ROOT__: release,
                __ENGRAM_EXPECTED_HOME__: options['expected-home'],
                __ENGRAM_SETTINGS__: options.settings,
                __ENGRAM_CREDENTIALS__: options['credentials-file'],
                ...(options.role === 'service-index'
                  ? {
                      __ENGRAM_DATABASE_PATH__: options['database-path'],
                      __ENGRAM_SERVICE_SOCKET__: options['service-socket'],
                      __ENGRAM_CAPTURE_SOURCE_AUTHORITY__:
                        options['capture-source-authority-file'] ?? null,
                    }
                  : {}),
              },
        disabled: keys.disabled,
        runAtLoad: keys.runAtLoad,
        keepAlive: keys.keepAlive,
        mode: '0600',
        overwrite,
      },
      ...(kind === 'install'
        ? [
            {
              operation: 'create-current-symlink',
              path: current,
              target: release,
              overwrite: false,
            },
          ]
        : [
            {
              operation: 'swap-current-symlink',
              path: current,
              target: release,
              previous: previousRelease,
              atomic: true,
            },
            {
              operation: 'record-rollback-pointer',
              path: targets.rollbackPointer,
              target: previousRelease,
              previous: previousPointer,
              atomic: true,
            },
          ]),
    ],
    blockersBeforeApply: [
      'separately authorized host transaction (apply-headless-install.mjs with this planHash)',
      'refresh process/job/socket/lock identity and backups',
      ...(credentials?.status === 'absent'
        ? [
            `provision owner-only 0600 credentials for ${credentials.expectedIDs.join(',')} out of band before activation`,
          ]
        : []),
      'verify settings role, source coverage and owner-only credential files without exposing values',
      'review exact rendered wrapper/plist bytes and rollback before any activation',
    ],
  };
}

// Read-only launchd probe: `launchctl print` of one label in the gui domain.
export function probeLaunchdLabel(launchctl, domain, label) {
  const result = spawnSync(launchctl, ['print', `${domain}/${label}`], {
    env: { PATH: '/usr/bin:/bin:/usr/sbin:/sbin', LC_ALL: 'C' },
    encoding: 'utf8',
    timeout: 10_000,
    maxBuffer: 1024 * 1024,
  });
  if (result.error || result.signal) fail('launchd probe failed');
  if (result.status === 0) {
    const match = /^\s*path = (.+?)\s*$/m.exec(result.stdout);
    return { loaded: true, path: match ? match[1] : null };
  }
  if (
    result.status === 113 ||
    /Could not find service/i.test(`${result.stdout}${result.stderr}`)
  )
    return { loaded: false, path: null };
  fail('launchd probe failed');
}

export function runVerifier(directory, script, bundle) {
  const environment = { PATH: '/usr/bin:/bin:/usr/sbin:/sbin', LC_ALL: 'C' };
  if (process.env.DEVELOPER_DIR)
    environment.DEVELOPER_DIR = process.env.DEVELOPER_DIR;
  const result = spawnSync(
    '/bin/bash',
    [join(directory, script), '--verify-only', bundle],
    {
      env: environment,
      encoding: 'utf8',
      timeout: 30_000,
      maxBuffer: 1024 * 1024,
    },
  );
  return !(result.error || result.signal || result.status !== 0);
}

export function readMetadata(bundle) {
  const metadataPath = join(bundle, 'BUILD-METADATA.json');
  const metadataStat = statIfPresent(metadataPath);
  if (!metadataStat?.isFile() || metadataStat.size > 64 * 1024)
    fail('invalid package metadata');
  return JSON.parse(readFileSync(metadataPath, 'utf8'));
}

// Same shape rules as assert_safe_relative_path in macos/scripts/package-*.sh.
function safeManifestPath(value) {
  return (
    value !== '' &&
    value !== 'SHA256SUMS' &&
    !value.startsWith('/') &&
    !value.endsWith('/') &&
    !value.includes('..') &&
    !value.includes('\\') &&
    value.split('/').every((component) => component && component !== '.')
  );
}
// Regular files only, like `find . -type f`; symlinks are neither listed nor followed.
function listRegularFiles(directory, relative = '', depth = 0, into = []) {
  if (depth > 16) fail('installed release is nested too deeply');
  for (const entry of readdirSync(join(directory, relative), {
    withFileTypes: true,
  })) {
    const child = relative ? `${relative}/${entry.name}` : entry.name;
    if (entry.isDirectory())
      listRegularFiles(directory, child, depth + 1, into);
    else if (entry.isFile() && child !== 'SHA256SUMS') into.push(child);
  }
  return into;
}
// An already installed release is verified against its own SHA256SUMS and
// BUILD-METADATA, never against the checkout's current templates: the
// package-*.sh --verify-only template check compares bytes with the checkout,
// which rejects every release packaged before a template change.
export function verifyInstalledRelease(bundle, role) {
  const manifestPath = join(bundle, 'SHA256SUMS');
  const manifestInfo = statIfPresent(manifestPath);
  if (!manifestInfo?.isFile() || manifestInfo.size > 1024 * 1024)
    fail('installed release lacks a regular SHA256SUMS');
  const listed = new Map();
  const lines = readFileSync(manifestPath, 'utf8').split('\n');
  if (lines.pop() !== '')
    fail('installed release SHA256SUMS has an invalid line');
  for (const line of lines) {
    const match = /^([0-9a-f]{64}) {2}(\S+)$/.exec(line);
    if (!match || !safeManifestPath(match[2]) || listed.has(match[2]))
      fail('installed release SHA256SUMS has an invalid line');
    listed.set(match[2], match[1]);
  }
  const files = listRegularFiles(bundle);
  if (files.length !== listed.size || files.some((file) => !listed.has(file)))
    fail('installed release SHA256SUMS does not exactly cover its files');
  for (const [relative, digest] of listed) {
    if (digestFile(join(bundle, relative)) !== digest)
      fail(`installed release file does not match SHA256SUMS: ${relative}`);
  }
  for (const [name, mode] of [
    [`${role.wrapper}.template`, 0o700],
    [`${role.label}.plist.template`, 0o600],
  ]) {
    const info = statIfPresent(join(bundle, 'templates', name));
    if (!info?.isFile() || (info.mode & 0o777) !== mode)
      fail(
        'installed release template is missing, aliased or has the wrong mode',
      );
  }
  const metadata = readMetadata(bundle);
  if (
    metadata.product !== role.product ||
    !/^[0-9a-f]{40}$/.test(metadata.sourceRevision ?? '')
  )
    fail('installed release metadata does not match the role');
  return {
    manifestDigest: digestFile(manifestPath),
    files: listed.size,
    sourceRevision: metadata.sourceRevision,
  };
}

function main() {
  const options = parseArguments(process.argv.slice(2));
  const role = roles[options.role];
  const verifierDirectory =
    options['verifier-directory'] ??
    resolve(dirname(fileURLToPath(import.meta.url)), '../macos/scripts');
  const launchctl = options.launchctl ?? '/bin/launchctl';
  let bundle = options.package;
  if (options.kind === 'rollback') {
    const pointer = join(options['install-root'], 'rollback');
    path(pointer, true);
    bundle = symlinkTarget(pointer, join(options['install-root'], 'releases'));
    if (!bundle) fail('rollback requires a rollback pointer');
    verifyInstalledRelease(bundle, role);
  } else {
    validatePackageTemplates(options);
    if (!runVerifier(verifierDirectory, role.verifier, bundle))
      fail('package verification failed; no installation plan produced');
  }
  const metadata = readMetadata(bundle);
  const launchd = probeLaunchdLabel(
    launchctl,
    `gui/${process.getuid()}`,
    role.label,
  );
  const plan = makeInstallationPlan(options, metadata, { launchd });
  plan.packageVerified = true;
  // The executor re-checks these before copying or activating anything.
  plan.packageDigest = digestFile(join(bundle, 'SHA256SUMS'));
  plan.verifierDirectory = verifierDirectory;
  plan.launchctl = launchctl;
  plan.planHash = canonicalPlanHash(plan);
  process.stdout.write(`${JSON.stringify(plan, null, 2)}\n`);
}

if (
  process.argv[1] &&
  resolve(process.argv[1]) === fileURLToPath(import.meta.url)
) {
  try {
    main();
  } catch (error) {
    process.stderr.write(`headless-install-plan: ${error.message}\n`);
    process.exitCode = 1;
  }
}
