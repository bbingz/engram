#!/usr/bin/env node
// Repository-only collector settings renderer. Never bundled (docs/invariants.md
// #7). It renders the owner-only settings document that the Swift collector
// settings parser accepts (macos/EngramCollectorCore/CollectorRuntime.swift,
// CollectorRuntimeConfiguration.load). It takes credential IDs only and never
// reads or writes credential values. Budget values come from an owner-reviewed
// profile file; there are deliberately no built-in budget defaults.
import {
  closeSync,
  fchmodSync,
  lstatSync,
  openSync,
  readFileSync,
  writeSync,
} from 'node:fs';
import { basename, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

// Source name -> accepted explicit parseFormat values (CollectorRuntime.swift
// rootFormat). An omitted parseFormat always maps to the source default.
const sources = {
  codex: ['codex'],
  'claude-code': ['claudeDefault', 'claudeCustomProfile'],
  qwen: ['qwen'],
  qoder: ['qoder'],
  iflow: ['iflow'],
  vscode: ['vscode'],
  cline: ['cline'],
  commandcode: ['commandcode'],
  copilot: ['copilot'],
  'gemini-cli': ['gemini-cli'],
  opencode: ['opencode'],
  kimi: ['kimi'],
  cursor: ['cursor'],
  antigravity: ['antigravityCLITranscript'],
  windsurf: ['windsurfHookTranscript'],
  pi: ['pi'],
  grok: ['grok'],
};
// Mirrors CollectorRuntimeConfiguration.Budgets.valid; maxResponseBytes is
// bounded by CollectorPublicationProtocolLimits.maxAcceptanceRecordBytes.
const budgetRanges = {
  maxEntriesVisited: [1, 4096],
  maxCandidateFiles: [1, 1024],
  maxDirectoryOpens: [1, 128],
  maxMetadataBytes: [512, 1_048_576],
  maxCaptureFiles: [1, 64],
  maxCaptureBytes: [1, 1_073_741_824],
  maxUploadClaimsPerReplica: [1, 64],
  maxRecoveryCandidates: [1, 64],
  maxResponseBytes: [1, 4096],
  minimumFreeDiskBytes: [0, Number.MAX_SAFE_INTEGER],
  maxIncomingPaths: [1, 1024],
  maxPathUTF8Bytes: [1, 65_536],
  maxTotalPathUTF8Bytes: [1, 1_048_576],
  maxCheckpointUTF8Bytes: [128, 4096],
  maxQueuedBatches: [1, 64],
  maxQueuedUTF8Bytes: [512, 8_388_608],
  pollIntervalMilliseconds: [10, 60_000],
};
const single = [
  'home',
  'identity-catalog',
  'spool',
  'hq-url',
  'hq-credential-id',
  'm1-url',
  'm1-credential-id',
  'privacy-revision',
  'root-revision',
  'budget-profiles',
  'budget-profile',
  'output',
];
const repeated = [
  'root',
  'parse-format',
  'project-registry',
  'exclude-project-root',
];
const required = [
  'home',
  'root',
  'identity-catalog',
  'spool',
  'hq-url',
  'hq-credential-id',
  'm1-url',
  'm1-credential-id',
  'budget-profiles',
  'budget-profile',
  'output',
];

function fail(message) {
  throw new Error(message);
}
function overlaps(a, b) {
  return a === b || a.startsWith(`${b}/`) || b.startsWith(`${a}/`);
}
// CollectorRuntime.swift identifier(): 1...128 bytes of [A-Za-z0-9._-].
function identifier(value) {
  return typeof value === 'string' && /^[A-Za-z0-9._-]{1,128}$/.test(value);
}
// CollectorRuntime.swift validPath(): absolute, at most MAXPATHLEN-1 bytes,
// no NUL, no empty/./.. components, at most 32 components.
export function validPath(value) {
  if (
    typeof value !== 'string' ||
    !value.startsWith('/') ||
    Buffer.byteLength(value) > 1023 ||
    value.includes('\0')
  )
    return false;
  const components = value.slice(1).split('/');
  return (
    components.length <= 32 &&
    components.every(
      (component) => component && component !== '.' && component !== '..',
    )
  );
}
// CollectorRuntime.swift endpoint(): https anywhere, http only on loopback,
// no credentials/query/fragment, empty or "/" path, printable ASCII, no "%".
export function endpoint(value) {
  if (
    typeof value !== 'string' ||
    Buffer.byteLength(value) > 2048 ||
    !/^[\x21-\x7e]+$/.test(value) ||
    value.includes('%')
  )
    return null;
  const match =
    /^(https?):\/\/([A-Za-z0-9.-]+|\[[0-9A-Fa-f:.]+\])(?::([0-9]{1,5}))?\/?$/.exec(
      value,
    );
  if (!match) return null;
  const [, scheme, host, port] = match;
  const number =
    port === undefined ? (scheme === 'https' ? 443 : 80) : Number(port);
  if (number < 1 || number > 65535) return null;
  if (scheme === 'http' && !['127.0.0.1', '[::1]'].includes(host)) return null;
  return `${scheme}://${host.toLowerCase()}:${number}`;
}
function positiveInteger(value, name) {
  if (value === undefined) return 1;
  if (!/^[1-9][0-9]{0,15}$/.test(value))
    fail(`${name} must be a positive integer`);
  return Number(value);
}
function sorted(value) {
  if (Array.isArray(value)) return value.map(sorted);
  if (value && typeof value === 'object')
    return Object.fromEntries(
      Object.keys(value)
        .sort()
        .map((key) => [key, sorted(value[key])]),
    );
  return value;
}

export function parseArguments(argv) {
  const values = {};
  const lists = Object.fromEntries(repeated.map((key) => [key, []]));
  for (let i = 0; i < argv.length; i++) {
    const key = argv[i].startsWith('--') ? argv[i].slice(2) : '';
    if (!single.includes(key) && !repeated.includes(key))
      fail('unknown option');
    if (++i >= argv.length || argv[i].startsWith('--'))
      fail('missing option value');
    if (repeated.includes(key)) lists[key].push(argv[i]);
    else if (Object.hasOwn(values, key)) fail('duplicate option');
    else values[key] = argv[i];
  }
  for (const key of required) {
    if (repeated.includes(key) ? lists[key].length === 0 : !values[key])
      fail(`missing required option --${key}`);
  }
  return { ...values, ...lists };
}

function expand(value, home) {
  if (value === '~') return home;
  return value.startsWith('~/') ? home + value.slice(1) : value;
}
function keyed(entries, name) {
  const map = new Map();
  for (const entry of entries) {
    const separator = entry.indexOf('=');
    if (separator < 1 || separator === entry.length - 1)
      fail(`--${name} expects ROOT_ID=VALUE`);
    const key = entry.slice(0, separator);
    if (map.has(key)) fail(`duplicate --${name} for ${key}`);
    map.set(key, entry.slice(separator + 1));
  }
  return map;
}

export function loadBudgetProfile(text, name) {
  let parsed;
  try {
    parsed = JSON.parse(text);
  } catch {
    fail('budget profile file is not JSON');
  }
  if (
    !parsed ||
    typeof parsed !== 'object' ||
    Array.isArray(parsed) ||
    Object.keys(parsed).join() !== 'profiles' ||
    !parsed.profiles ||
    typeof parsed.profiles !== 'object' ||
    Array.isArray(parsed.profiles)
  )
    fail('budget profile file must be {"profiles": {...}}');
  if (!identifier(name) || !Object.hasOwn(parsed.profiles, name))
    fail('unknown budget profile');
  const profile = parsed.profiles[name];
  const expected = Object.keys(budgetRanges);
  if (
    !profile ||
    typeof profile !== 'object' ||
    Array.isArray(profile) ||
    Object.keys(profile).sort().join() !== [...expected].sort().join()
  )
    fail('budget profile must define exactly the collector budget keys');
  for (const key of expected) {
    const value = profile[key];
    const [minimum, maximum] = budgetRanges[key];
    if (!Number.isSafeInteger(value) || value < minimum || value > maximum)
      fail(`budget ${key} is outside the collector range`);
  }
  return Object.fromEntries(expected.map((key) => [key, profile[key]]));
}

export function renderCollectorSettings(options, profileText) {
  const home = options.home;
  if (!validPath(home)) fail('home must be a normalized absolute path');
  const shadowRoot = expand(options.spool, home);
  const identityCatalog = expand(options['identity-catalog'], home);
  if (!validPath(shadowRoot) || !validPath(identityCatalog))
    fail('spool and identity catalog must be normalized absolute paths');
  if (basename(identityCatalog) !== 'archive.sqlite')
    fail('identity catalog must be named archive.sqlite');
  const catalogParent = dirname(identityCatalog);
  if (overlaps(shadowRoot, catalogParent))
    fail('spool and identity catalog directory must not overlap');
  const formats = keyed(options['parse-format'], 'parse-format');
  const registries = keyed(options['project-registry'], 'project-registry');
  const revision = positiveInteger(options['root-revision'], 'root revision');
  const ids = new Set();
  const roots = options.root.map((entry) => {
    const [rootID, source, ...rest] = entry.split(':');
    const rootPath = expand(rest.join(':'), home);
    if (!identifier(rootID) || ids.has(rootID))
      fail('invalid or duplicate root ID');
    ids.add(rootID);
    if (!Object.hasOwn(sources, source)) fail(`unsupported source ${source}`);
    if (!validPath(rootPath)) fail(`root ${rootID} path is not normalized`);
    if (overlaps(rootPath, shadowRoot) || overlaps(rootPath, catalogParent))
      fail(`root ${rootID} overlaps the spool or identity catalog`);
    const root = { rootID, source, rootPath, revision };
    const parseFormat = formats.get(rootID);
    if (parseFormat !== undefined) {
      if (!sources[source].includes(parseFormat))
        fail(`parse format ${parseFormat} is not valid for ${source}`);
      root.parseFormat = parseFormat;
    }
    const registry = registries.get(rootID);
    if (source === 'kimi' && registry === undefined)
      fail(`kimi root ${rootID} requires --project-registry`);
    if (registry !== undefined) {
      if (source !== 'kimi' && source !== 'gemini-cli')
        fail(`source ${source} does not take a project registry`);
      const registryPath = expand(registry, home);
      if (
        !validPath(registryPath) ||
        overlaps(registryPath, rootPath) ||
        overlaps(registryPath, shadowRoot) ||
        overlaps(registryPath, catalogParent)
      )
        fail(`project registry for ${rootID} is invalid or overlaps`);
      root.projectRegistryPath = registryPath;
    }
    return root;
  });
  for (const key of [...formats.keys(), ...registries.keys()])
    if (!ids.has(key)) fail(`option names unknown root ${key}`);
  if (roots.length > 64) fail('at most 64 roots are supported');
  const replicas = [
    ['hq', options['hq-url'], options['hq-credential-id']],
    ['m1', options['m1-url'], options['m1-credential-id']],
  ].map(([serverID, baseURL, credentialID]) => {
    if (!endpoint(baseURL))
      fail(`${serverID} replica URL is not a valid endpoint`);
    if (!identifier(credentialID)) fail(`${serverID} credential ID is invalid`);
    return { serverID, baseURL, credentialID };
  });
  if (
    endpoint(replicas[0].baseURL) === endpoint(replicas[1].baseURL) ||
    replicas[0].credentialID === replicas[1].credentialID
  )
    fail('replica endpoints and credential IDs must be distinct');
  const excludedProjectRoots = options['exclude-project-root'].map((value) => {
    const path = expand(value, home);
    if (!validPath(path)) fail('excluded project root is not normalized');
    return path;
  });
  if (excludedProjectRoots.length > 128)
    fail('at most 128 excluded project roots are supported');
  return sorted({
    runtimeRole: 'collector',
    collector: {
      enabled: true,
      shadowRoot,
      identityCatalog,
      roots,
      replicas,
      privacy: {
        revision: positiveInteger(
          options['privacy-revision'],
          'privacy revision',
        ),
        excludedProjectRoots,
      },
      budgets: loadBudgetProfile(profileText, options['budget-profile']),
    },
  });
}

function writeOwnerOnly(path, text) {
  if (!validPath(path)) fail('output must be a normalized absolute path');
  for (let current = path; current !== '/'; current = dirname(current)) {
    try {
      if (lstatSync(current).isSymbolicLink())
        fail('output path has a symlink alias');
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
    }
  }
  // wx: an existing settings file is never overwritten by this tool.
  const descriptor = openSync(path, 'wx', 0o600);
  try {
    fchmodSync(descriptor, 0o600);
    writeSync(descriptor, text);
  } finally {
    closeSync(descriptor);
  }
}

function main() {
  const options = parseArguments(process.argv.slice(2));
  const profiles = expand(options['budget-profiles'], options.home);
  const info = lstatSync(profiles);
  if (!info.isFile() || info.size > 64 * 1024)
    fail('invalid budget profile file');
  const document = renderCollectorSettings(
    options,
    readFileSync(profiles, 'utf8'),
  );
  const output = expand(options.output, options.home);
  writeOwnerOnly(output, `${JSON.stringify(document, null, 2)}\n`);
  process.stdout.write(
    `${JSON.stringify({
      kind: 'collector-settings-rendered',
      output,
      mode: '0600',
      roots: document.collector.roots.length,
      budgetProfile: options['budget-profile'],
      credentialIDs: document.collector.replicas.map(
        (replica) => replica.credentialID,
      ),
    })}\n`,
  );
}

if (
  process.argv[1] &&
  resolve(process.argv[1]) === fileURLToPath(import.meta.url)
) {
  try {
    main();
  } catch (error) {
    process.stderr.write(`render-collector-settings: ${error.message}\n`);
    process.exitCode = 1;
  }
}
