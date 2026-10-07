#!/usr/bin/env node
// Repository-only plan executor (design §4.6, decision D12). Never bundled.
// It applies exactly one plan printed by plan-headless-install.mjs, and only
// when the canonical plan hash matches both the owner-supplied --plan-hash and
// the hash embedded in the plan. It never opens settings, credentials or env
// files, and it runs no launchctl command unless --activate is passed.
import { spawnSync } from 'node:child_process';
import {
  closeSync,
  cpSync,
  fchmodSync,
  lstatSync,
  mkdirSync,
  openSync,
  readFileSync,
  readlinkSync,
  renameSync,
  rmSync,
  symlinkSync,
  writeSync,
} from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  canonicalPlanHash,
  digestFile,
  optionalSlots,
  path,
  readMetadata,
  roles,
  verifyInstalledRelease,
} from './plan-headless-install.mjs';

const kinds = ['installation-dry-run', 'upgrade-dry-run', 'rollback-dry-run'];
const operations = new Set([
  'copy-new-release',
  'verify-copied-release',
  'verify-existing-release',
  'initialize-collector-identity',
  'initialize-collector-spool',
  'render-wrapper',
  'render-launch-agent',
  'create-current-symlink',
  'swap-current-symlink',
  'record-rollback-pointer',
]);
const environment = { PATH: '/usr/bin:/bin:/usr/sbin:/sbin', LC_ALL: 'C' };
// After bootout, launchd unloads asynchronously; bootstrap must wait for it.
const unloadAttempts = 30;
const unloadIntervalMilliseconds = 1000;

function fail(message) {
  throw new Error(message);
}
function statIfPresent(target) {
  try {
    return lstatSync(target);
  } catch (error) {
    if (error.code === 'ENOENT') return null;
    throw error;
  }
}

export function parseArguments(argv) {
  const values = {};
  const options = ['plan', 'plan-hash', 'launchctl', 'verifier-directory'];
  for (let i = 0; i < argv.length; i++) {
    const key = argv[i].startsWith('--') ? argv[i].slice(2) : '';
    if (key === 'activate') {
      if (values.activate) fail('duplicate --activate');
      values.activate = true;
      continue;
    }
    if (!options.includes(key)) fail('unknown option');
    if (Object.hasOwn(values, key)) fail('duplicate option');
    if (++i >= argv.length || argv[i].startsWith('--'))
      fail('missing option value');
    values[key] = argv[i];
  }
  if (!values.plan || !values['plan-hash'])
    fail('--plan and --plan-hash are required');
  if (!/^[0-9a-f]{64}$/.test(values['plan-hash'])) fail('invalid plan hash');
  for (const key of ['plan', 'launchctl', 'verifier-directory'])
    if (values[key]) path(values[key]);
  return values;
}

export function loadPlan(file, expectedHash) {
  const info = lstatSync(file);
  if (!info.isFile() || info.size > 1024 * 1024)
    fail('plan must be a regular file');
  const plan = JSON.parse(readFileSync(file, 'utf8'));
  if (!plan || typeof plan !== 'object' || Array.isArray(plan))
    fail('plan is not an object');
  const hash = canonicalPlanHash(plan);
  if (hash !== expectedHash || plan.planHash !== expectedHash)
    fail('plan hash mismatch; refusing to apply');
  if (plan.packageVerified !== true)
    fail('plan was not produced by a verified planner run');
  if (
    !/^[0-9a-f]{64}$/.test(plan.packageDigest ?? '') ||
    !Object.hasOwn(roles, plan.role) ||
    roles[plan.role].product !== plan.product ||
    !/^[0-9a-f]{40}$/.test(plan.sourceRevision ?? '')
  )
    fail('plan lacks a package digest, product or revision');
  if (!kinds.includes(plan.kind)) fail('unsupported plan kind');
  if (
    !Array.isArray(plan.steps) ||
    !plan.steps.every((step) => operations.has(step?.operation))
  )
    fail('plan contains an unsupported step');
  if (!Array.isArray(plan.activation?.commands))
    fail('plan lacks activation commands');
  for (const [name, target] of Object.entries(plan.targets ?? {}))
    path(target, name === 'current' || name === 'rollbackPointer');
  return plan;
}

// A symlink's target resolved against its own directory, so a hand-made
// relative `current -> releases/<rev>` compares equal to the planned path.
function link(target) {
  const info = statIfPresent(target);
  if (!info) return null;
  if (!info.isSymbolicLink()) fail(`${target} is not a symlink`);
  return resolve(dirname(target), readlinkSync(target));
}

// The plan recorded the host state it assumed; refuse to apply onto anything else.
function preflight(plan) {
  const { release, current, wrapper, launchAgent, rollbackPointer } =
    plan.targets;
  if (plan.transaction === 'install') {
    for (const target of [
      release,
      current,
      wrapper,
      launchAgent,
      rollbackPointer,
    ])
      if (statIfPresent(target)) fail('existing target would be overwritten');
    return;
  }
  if (link(current) !== plan.previousRelease)
    fail('current release changed since planning');
  for (const target of [wrapper, launchAgent]) {
    const info = statIfPresent(target);
    if (info ? !info.isFile() : plan.transaction === 'rollback')
      fail('wrapper or launch agent target changed since planning');
  }
  if (plan.transaction === 'upgrade') {
    if (statIfPresent(release)) fail('release already exists');
  } else if (link(rollbackPointer) !== release)
    fail('rollback pointer changed since planning');
}

function escapeXML(value) {
  return value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');
}

export function renderTemplate(text, bindings, kind) {
  let output = text;
  for (const [token, value] of Object.entries(bindings)) {
    if (value === null) {
      const flag = optionalSlots[token];
      if (kind !== 'plist' || !flag) fail(`no optional slot for ${token}`);
      output = output
        .split('\n')
        .filter((line) => {
          const trimmed = line.trim();
          return (
            trimmed !== `<string>${flag}</string>` &&
            trimmed !== `<string>${token}</string>`
          );
        })
        .join('\n');
      continue;
    }
    if (typeof value !== 'string' || /[\x00-\x1f\x7f]/.test(value))
      fail(`binding ${token} is not a printable string`);
    if (kind === 'zsh' && value.includes("'"))
      fail(`binding ${token} cannot be single-quoted for zsh`);
    const rendered = kind === 'plist' ? escapeXML(value) : value;
    output = output.replaceAll(token, rendered);
    // A packaged template may carry a pre-bound value (remote revision); it
    // must then equal the plan binding.
    if (!output.includes(rendered))
      fail(`template does not reflect binding ${token}`);
  }
  // Wrapper templates mention the literal '__ENGRAM_' prefix in their own
  // placeholder guard; only a complete token is an unbound placeholder.
  if (/__ENGRAM_[A-Z0-9_]+__/.test(output))
    fail('template still contains an unbound placeholder');
  return output;
}

function writeFile(destination, bytes, mode) {
  const temporary = `${destination}.${process.pid}.tmp`;
  const descriptor = openSync(temporary, 'wx', mode);
  try {
    fchmodSync(descriptor, mode);
    writeSync(descriptor, bytes);
  } finally {
    closeSync(descriptor);
  }
  renameSync(temporary, destination);
}

// Every file effect is recorded so a failed step can be undone: paths this
// run created are removed, overwritten files get their previous bytes back
// and swapped symlinks are re-pointed.
function writeOwnerOnly(destination, text, mode, overwrite, transaction) {
  const existing = statIfPresent(destination);
  if (existing && (!overwrite || !existing.isFile()))
    fail(`${destination} exists`);
  if (existing)
    transaction.restores.push({
      file: destination,
      bytes: readFileSync(destination),
      mode: existing.mode & 0o7777,
    });
  else transaction.created.push(destination);
  writeFile(destination, text, mode);
}

function pointSymlink(target, destination) {
  const temporary = `${destination}.${process.pid}.tmp`;
  symlinkSync(target, temporary);
  renameSync(temporary, destination);
}

function atomicSymlink(target, destination, previous, transaction) {
  if (link(destination) !== previous)
    fail(`${destination} changed since planning`);
  if (previous === null) transaction.created.push(destination);
  else transaction.restores.push({ symlink: destination, target: previous });
  pointSymlink(target, destination);
}

function undo(transaction) {
  const undone = [];
  for (const restore of transaction.restores.reverse()) {
    if (restore.symlink) pointSymlink(restore.target, restore.symlink);
    else writeFile(restore.file, restore.bytes, restore.mode);
    undone.push(restore.symlink ?? restore.file);
  }
  for (const created of transaction.created.reverse()) {
    rmSync(created, { recursive: true, force: true });
    undone.push(created);
  }
  return undone;
}

function spawn(executable, args, timeout) {
  return spawnSync(executable, args, {
    env: environment,
    encoding: 'utf8',
    timeout,
    maxBuffer: 1024 * 1024,
  });
}
function run(executable, args, timeout) {
  const result = spawn(executable, args, timeout);
  return !(result.error || result.signal || result.status !== 0);
}

// The plan hash pins the package bytes only through this check: the source
// must still carry the planned BUILD-METADATA and SHA256SUMS digest.
function bindPackage(source, plan) {
  const metadata = readMetadata(source);
  if (
    metadata.product !== plan.product ||
    metadata.sourceRevision !== plan.sourceRevision ||
    digestFile(resolve(source, 'SHA256SUMS')) !== plan.packageDigest
  )
    fail(
      'package changed since planning: BUILD-METADATA or SHA256SUMS differ from the plan; print a new plan',
    );
}

function applyStep(step, tools, transaction, plan) {
  switch (step.operation) {
    case 'copy-new-release': {
      bindPackage(step.source, plan);
      mkdirSync(dirname(step.destination), { recursive: true, mode: 0o700 });
      cpSync(step.source, step.destination, {
        recursive: true,
        errorOnExist: true,
        force: false,
        preserveTimestamps: true,
        verbatimSymlinks: true,
      });
      transaction.created.push(step.destination);
      return;
    }
    case 'verify-copied-release':
      if (
        !run(
          '/bin/bash',
          [
            resolve(tools.verifierDirectory, step.script),
            '--verify-only',
            step.bundle,
          ],
          30_000,
        )
      )
        fail('release verification failed');
      return;
    case 'verify-existing-release':
      // Never the checkout verifier: its template check is byte equality with
      // the checkout, which an older installed release legitimately fails.
      if (
        verifyInstalledRelease(step.bundle, roles[plan.role]).manifestDigest !==
        plan.packageDigest
      )
        fail('installed release changed since planning');
      return;
    case 'initialize-collector-identity':
    case 'initialize-collector-spool':
      if (!run(step.executable, step.arguments, 60_000))
        fail(`${step.operation} failed`);
      return;
    case 'render-wrapper':
    case 'render-launch-agent': {
      const kind = step.operation === 'render-wrapper' ? 'zsh' : 'plist';
      const rendered = renderTemplate(
        readFileSync(step.template, 'utf8'),
        step.bindings,
        kind,
      );
      writeOwnerOnly(
        step.destination,
        rendered,
        kind === 'zsh' ? 0o700 : 0o600,
        step.overwrite === true,
        transaction,
      );
      return;
    }
    case 'create-current-symlink':
      if (statIfPresent(step.path)) fail(`${step.path} exists`);
      symlinkSync(step.target, step.path);
      transaction.created.push(step.path);
      return;
    case 'swap-current-symlink':
    case 'record-rollback-pointer':
      atomicSymlink(step.target, step.path, step.previous, transaction);
      return;
    default:
      fail('unsupported step');
  }
}

function unloaded(result) {
  return (
    result.status === 113 ||
    /Could not find service/i.test(`${result.stdout}${result.stderr}`)
  );
}

// Bounded wait for launchd to finish unloading the label after bootout.
function waitUntilUnloaded(launchctl, service) {
  for (let attempt = 1; attempt <= unloadAttempts; attempt++) {
    if (unloaded(spawn(launchctl, ['print', service], 10_000))) return attempt;
    Atomics.wait(
      new Int32Array(new SharedArrayBuffer(4)),
      0,
      0,
      unloadIntervalMilliseconds,
    );
  }
  fail(`launchd still reports ${service} loaded after bootout`);
}

function activate(plan, tools, activation) {
  if (plan.credentials) {
    // Metadata only: the executor never opens the credentials file.
    const info = statIfPresent(plan.credentials.file);
    if (
      !info?.isFile() ||
      info.uid !== process.getuid() ||
      (info.mode & 0o7777) !== 0o600 ||
      info.nlink !== 1
    )
      fail(
        'refusing activation: credentials file is not an owner-only 0600 regular file',
      );
  }
  const commands = [...plan.activation.commands];
  while (commands.length) {
    const command = commands.shift();
    const ok = run(tools.launchctl, command, 30_000);
    activation.results.push({ command, ok });
    activation.remaining = commands;
    if (!ok) fail(`launchctl ${command[0]} failed`);
    if (command[0] === 'bootout') {
      activation.results.push({
        command: ['print', command[1]],
        ok: true,
        attempts: waitUntilUnloaded(tools.launchctl, command[1]),
      });
    }
  }
}

export function applyPlan(plan, tools) {
  preflight(plan);
  const report = {
    kind: 'apply-report',
    planHash: plan.planHash,
    transaction: plan.transaction,
    applied: [],
    activation: { launchctl: 'NOT_RUN', commands: plan.activation.commands },
  };
  const transaction = { created: [], restores: [] };
  try {
    for (const step of plan.steps) {
      applyStep(step, tools, transaction, plan);
      report.applied.push(step.operation);
    }
  } catch (error) {
    // A failed step leaves no half-applied release behind, so the owner can
    // print a new plan against the state the old plan assumed.
    report.rolledBack = undo(transaction);
    throw Object.assign(error, { report: { ...report, error: error.message } });
  }
  if (!tools.activate) return report;
  report.activation = {
    launchctl: tools.launchctl,
    results: [],
    remaining: plan.activation.commands,
  };
  try {
    activate(plan, tools, report.activation);
    report.activation.remaining = [];
    return report;
  } catch (error) {
    // File steps stay applied; the report names what launchctl still needs.
    const failed = report.activation.results.filter((entry) => !entry.ok);
    report.activation.manual = [
      ...failed,
      ...report.activation.remaining.map((command) => ({ command })),
    ].map((entry) => ['launchctl', ...entry.command].join(' '));
    throw Object.assign(error, { report: { ...report, error: error.message } });
  }
}

function main() {
  const options = parseArguments(process.argv.slice(2));
  const plan = loadPlan(options.plan, options['plan-hash']);
  const tools = {
    activate: options.activate === true,
    launchctl: options.launchctl ?? '/bin/launchctl',
    verifierDirectory:
      options['verifier-directory'] ??
      resolve(dirname(fileURLToPath(import.meta.url)), '../macos/scripts'),
  };
  // The plan was printed against specific host tools; apply with the same ones.
  if (
    plan.launchctl !== tools.launchctl ||
    plan.verifierDirectory !== tools.verifierDirectory
  )
    fail(
      'executor tools differ from the plan (launchctl or verifier directory); pass the planned ones',
    );
  const report = applyPlan(plan, tools);
  process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
}

if (
  process.argv[1] &&
  resolve(process.argv[1]) === fileURLToPath(import.meta.url)
) {
  try {
    main();
  } catch (error) {
    if (error.report)
      process.stdout.write(`${JSON.stringify(error.report, null, 2)}\n`);
    process.stderr.write(`apply-headless-install: ${error.message}\n`);
    process.exitCode = 1;
  }
}
