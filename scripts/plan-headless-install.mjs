#!/usr/bin/env node
// Repository-only installation planning. Never bundled or used to start a role.
// There is deliberately no apply mode, file writer, secret reader or launchctl.
import { spawnSync } from 'node:child_process';
import { lstatSync, readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const roles = {
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
const common = ['role', 'package', 'install-root', 'launch-agent-directory'];
const capture = ['expected-home', 'settings', 'credentials-file'];
const index = ['database-path', 'service-socket'];
const remote = ['legacy-env-file', 'archive-env-file'];

function fail(message) {
  throw new Error(message);
}
function overlaps(a, b) {
  return a === b || a.startsWith(`${b}/`) || b.startsWith(`${a}/`);
}
function statIfPresent(path) {
  try {
    return lstatSync(path);
  } catch (error) {
    if (error.code === 'ENOENT') return null;
    throw error;
  }
}
function path(value) {
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
    if (statIfPresent(current)?.isSymbolicLink())
      fail('path has a symlink alias');
  }
  return value;
}

export function parseArguments(argv) {
  const values = {};
  let dryRun = false;
  const known = new Set([...common, ...capture, ...index, ...remote]);
  for (let i = 0; i < argv.length; i++) {
    const flag = argv[i];
    if (flag === '--dry-run') {
      if (dryRun) fail('duplicate --dry-run');
      dryRun = true;
      continue;
    }
    const key = flag.startsWith('--') ? flag.slice(2) : '';
    if (!known.has(key))
      fail('unknown option; only explicit --dry-run is supported');
    if (Object.hasOwn(values, key)) fail('duplicate option');
    if (++i >= argv.length || argv[i].startsWith('--'))
      fail('missing option value');
    values[key] = argv[i];
  }
  if (!dryRun) fail('explicit --dry-run is required; apply is unavailable');
  if (!Object.hasOwn(roles, values.role)) fail('unknown role');
  const required = [
    ...common,
    ...(values.role === 'remote-server' ? remote : capture),
    ...(values.role === 'service-index' ? index : []),
  ];
  if (required.some((key) => !Object.hasOwn(values, key)))
    fail('missing required option');
  if (Object.keys(values).some((key) => !required.includes(key)))
    fail('unexpected cross-role option');
  for (const key of required) if (key !== 'role') path(values[key]);
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

export function makeInstallationPlan(options, metadata) {
  const role = roles[options.role];
  if (!role || metadata.product !== role.product)
    fail('package product does not match role');
  if (!/^[0-9a-f]{40}$/.test(metadata.sourceRevision ?? ''))
    fail('invalid source revision');
  const root = options['install-root'];
  const release = join(root, 'releases', metadata.sourceRevision);
  const current = join(root, 'current');
  const targets = {
    release,
    current,
    wrapper: join(root, role.wrapper),
    launchAgent: join(options['launch-agent-directory'], `${role.label}.plist`),
  };
  if (overlaps(root, options.package))
    fail('installation root overlaps package');
  if (
    overlaps(root, options['launch-agent-directory']) ||
    overlaps(options.package, options['launch-agent-directory'])
  )
    fail('job directory overlaps package or installation root');
  for (const target of Object.values(targets)) {
    path(target);
    if (statIfPresent(target))
      fail(
        'existing target would be overwritten; a separate upgrade transaction is required',
      );
  }
  for (const key of [...capture, ...index]) {
    const value = options[key];
    if (
      value &&
      (overlaps(value, join(root, 'releases')) ||
        overlaps(value, current) ||
        overlaps(value, targets.wrapper) ||
        overlaps(value, options.package) ||
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
      options['archive-env-file'] !== join(root, 'secrets/archive-v2.env'))
  )
    fail('remote secret locations must match the existing wrapper contract');
  const inputs = Object.fromEntries(
    Object.entries(options).map(([key, value]) => [
      key.replace(/-([a-z])/g, (_, letter) => letter.toUpperCase()),
      value,
    ]),
  );
  return {
    kind: 'installation-dry-run',
    role: options.role,
    sourceRevision: metadata.sourceRevision,
    packageVerified: false,
    deploymentAuthorized: false,
    inputs,
    targets,
    activation: {
      disabled: true,
      runAtLoad: false,
      keepAlive: false,
      launchctl: 'NOT_RUN',
    },
    steps: [
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
      {
        operation: 'render-wrapper',
        template: join(release, 'templates', `${role.wrapper}.template`),
        destination: targets.wrapper,
        bindings:
          options.role === 'remote-server'
            ? { __ENGRAM_REMOTE_ROOT__: root }
            : {},
        mode: '0700',
      },
      {
        operation: 'render-disabled-launch-agent',
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
                    }
                  : {}),
              },
        disabled: true,
        runAtLoad: false,
        keepAlive: false,
        mode: '0600',
      },
      {
        operation: 'create-current-symlink',
        path: current,
        target: release,
        overwrite: false,
      },
    ],
    blockersBeforeApply: [
      'separately authorized host transaction',
      'refresh process/job/socket/lock identity and backups',
      'verify settings role, source coverage and owner-only credential files without exposing values',
      'review exact rendered wrapper/plist bytes and rollback before any activation',
    ],
  };
}

function main() {
  const options = parseArguments(process.argv.slice(2));
  validatePackageTemplates(options);
  const role = roles[options.role];
  const verifier = resolve(
    dirname(fileURLToPath(import.meta.url)),
    '../macos/scripts',
    role.verifier,
  );
  const environment = { PATH: '/usr/bin:/bin:/usr/sbin:/sbin', LC_ALL: 'C' };
  if (process.env.DEVELOPER_DIR)
    environment.DEVELOPER_DIR = process.env.DEVELOPER_DIR;
  const result = spawnSync(
    '/bin/bash',
    [verifier, '--verify-only', options.package],
    {
      env: environment,
      encoding: 'utf8',
      timeout: 30_000,
      maxBuffer: 1024 * 1024,
    },
  );
  if (result.error || result.signal || result.status !== 0)
    fail('package verification failed; no installation plan produced');
  const metadataPath = join(options.package, 'BUILD-METADATA.json');
  const metadataStat = lstatSync(metadataPath);
  if (!metadataStat.isFile() || metadataStat.size > 64 * 1024)
    fail('invalid package metadata');
  const plan = makeInstallationPlan(
    options,
    JSON.parse(readFileSync(metadataPath, 'utf8')),
  );
  plan.packageVerified = true;
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
