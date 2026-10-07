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
  optionalSlots,
  path,
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

function link(target) {
  const info = statIfPresent(target);
  if (!info) return null;
  if (!info.isSymbolicLink()) fail(`${target} is not a symlink`);
  return readlinkSync(target);
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

function writeOwnerOnly(destination, text, mode, overwrite) {
  const existing = statIfPresent(destination);
  if (existing && (!overwrite || !existing.isFile()))
    fail(`${destination} exists`);
  const temporary = `${destination}.${process.pid}.tmp`;
  const descriptor = openSync(temporary, 'wx', mode);
  try {
    fchmodSync(descriptor, mode);
    writeSync(descriptor, text);
  } finally {
    closeSync(descriptor);
  }
  renameSync(temporary, destination);
}

function atomicSymlink(target, destination, previous) {
  if (link(destination) !== previous)
    fail(`${destination} changed since planning`);
  const temporary = `${destination}.${process.pid}.tmp`;
  symlinkSync(target, temporary);
  renameSync(temporary, destination);
}

function run(executable, args, timeout) {
  const result = spawnSync(executable, args, {
    env: environment,
    encoding: 'utf8',
    timeout,
    maxBuffer: 1024 * 1024,
  });
  return !(result.error || result.signal || result.status !== 0);
}

function applyStep(step, tools, created) {
  switch (step.operation) {
    case 'copy-new-release': {
      mkdirSync(dirname(step.destination), { recursive: true, mode: 0o700 });
      cpSync(step.source, step.destination, {
        recursive: true,
        errorOnExist: true,
        force: false,
        preserveTimestamps: true,
        verbatimSymlinks: true,
      });
      created.push(step.destination);
      return;
    }
    case 'verify-copied-release':
    case 'verify-existing-release':
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
      ) {
        // Remove only a release this run copied; never an existing one.
        if (created.includes(step.bundle))
          rmSync(step.bundle, { recursive: true, force: true });
        fail('release verification failed');
      }
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
      );
      return;
    }
    case 'create-current-symlink':
      if (statIfPresent(step.path)) fail(`${step.path} exists`);
      symlinkSync(step.target, step.path);
      return;
    case 'swap-current-symlink':
    case 'record-rollback-pointer':
      atomicSymlink(step.target, step.path, step.previous);
      return;
    default:
      fail('unsupported step');
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
  const created = [];
  try {
    for (const step of plan.steps) {
      applyStep(step, tools, created);
      report.applied.push(step.operation);
    }
    if (!tools.activate) return report;
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
    report.activation = { launchctl: tools.launchctl, results: [] };
    for (const command of plan.activation.commands) {
      const ok = run(tools.launchctl, command, 30_000);
      report.activation.results.push({ command, ok });
      if (!ok) fail(`launchctl ${command[0]} failed`);
    }
    return report;
  } catch (error) {
    // Applied steps are reported so the owner can see the partial state.
    throw Object.assign(error, { report: { ...report, error: error.message } });
  }
}

function main() {
  const options = parseArguments(process.argv.slice(2));
  const plan = loadPlan(options.plan, options['plan-hash']);
  const report = applyPlan(plan, {
    activate: options.activate === true,
    launchctl: options.launchctl ?? '/bin/launchctl',
    verifierDirectory:
      options['verifier-directory'] ??
      resolve(dirname(fileURLToPath(import.meta.url)), '../macos/scripts'),
  });
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
